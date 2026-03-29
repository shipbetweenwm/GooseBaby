#!/usr/bin/env node
/**
 * Playwright Persistent Server
 * 
 * 通过 stdin/stdout JSON 协议与 Dart 端通信，保持浏览器长期运行。
 * 
 * 协议：
 * - stdin: 每行一个 JSON 指令 { action, args, id }
 * - stdout: 每行一个 JSON 响应 { id, success, ... }
 * - stderr: 日志输出（非协议数据）
 * 
 * 支持的 action：
 * - open/navigate/click/fill/... : 执行浏览器操作
 * - close: 关闭浏览器（进程不退出，可再次 open）
 * - exit: 退出整个服务进程
 */

const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

let browser = null;
let context = null;
let page = null;

// 处理单个指令
async function handleCommand(cmd) {
  const { action, args = {}, id } = cmd;
  
  try {
    switch (action) {
      // === 浏览器生命周期 ===
      case 'launch': {
        if (browser) {
          // 浏览器已存在，复用
          const pages = context ? context.pages() : browser.pages();
          page = pages.length > 0 ? pages[0] : (context ? await context.newPage() : (await browser.newPage()));
          return { id, success: true, message: '浏览器已在运行', url: page.url() };
        }
        const headless = args.headless !== undefined ? args.headless : false;
        const slowMo = args.slow_mo || 0;
        browser = await chromium.launch({ headless, slowMo });
        context = await browser.newContext({
          viewport: { width: args.viewport_width || 1920, height: args.viewport_height || 1080 },
          ...(args.user_agent ? { userAgent: args.user_agent } : {}),
          ...(args.ignore_https_errors ? { ignoreHTTPSErrors: true } : {}),
        });
        if (args.block_resources) {
          const resources = Array.isArray(args.block_resources) ? args.block_resources : [args.block_resources];
          await context.route('**', async route => {
            if (resources.includes(route.request().resourceType())) {
              await route.abort();
              return;
            }
            await route.continue();
          });
        }
        if (args.cookies) {
          let cookies = args.cookies;
          if (typeof cookies === 'string') {
            try { cookies = JSON.parse(cookies); } catch (_) {}
          }
          if (Array.isArray(cookies)) {
            await context.addCookies(cookies);
          }
        }
        page = await context.newPage();
        page.setDefaultTimeout(args.timeout || 30000);
        return { id, success: true, message: '浏览器已启动' };
      }

      case 'close': {
        if (browser) {
          try {
            await Promise.race([
              browser.close(),
              new Promise(r => setTimeout(r, 5000)),
            ]);
          } catch (_) {}
          browser = null;
          context = null;
          page = null;
        }
        return { id, success: true, message: '浏览器已关闭' };
      }

      case 'exit': {
        if (browser) {
          try { await Promise.race([browser.close(), new Promise(r => setTimeout(r, 3000))]); } catch (_) {}
        }
        // 给 Dart 端一点时间读取响应
        setTimeout(() => process.exit(0), 200);
        return { id, success: true, message: '服务进程退出中' };
      }

      // === 导航 ===
      case 'navigate':
      case 'open': {
        await ensureBrowser(args);
        const url = args.url || '';
        const waitUntil = args.wait_until || 'domcontentloaded';
        await page.goto(url, { waitUntil, timeout: args.timeout || 60000 });
        if (args.wait_for) {
          await page.waitForSelector(args.wait_for, { timeout: args.timeout || 30000 });
        }
        const title = await page.title();
        const pageUrl = page.url();
        return { id, success: true, title, url: pageUrl };
      }

      // === 点击 ===
      case 'click': {
        await ensureBrowser(args);
        const { selector, text, role, name, label, position, wait_for_navigation, wait_for } = args;
        if (text) {
          await page.getByText(text).first().click();
        } else if (role) {
          await page.getByRole(role, name ? { name } : {}).first().click();
        } else if (label) {
          await page.getByLabel(label).first().click();
        } else if (position) {
          await page.mouse.click(position.x, position.y);
        } else if (selector) {
          await page.click(selector);
        } else {
          return { id, success: false, error: '需要 selector、text、role、label 或 position' };
        }
        if (wait_for_navigation) {
          await page.waitForLoadState('domcontentloaded');
        } else if (wait_for) {
          await page.waitForSelector(wait_for, { timeout: args.timeout || 30000 });
        }
        const pageUrl = page.url();
        const title = await page.title();
        return { id, success: true, url: pageUrl, title, message: '已点击元素' };
      }

      // === 填写 ===
      case 'fill': {
        await ensureBrowser(args);
        const { selector, label, placeholder, value = '', press_enter, submit, submit_selector } = args;
        const escaped = escapeJs(value);
        if (label) {
          await page.getByLabel(label).fill(escaped);
        } else if (placeholder) {
          await page.getByPlaceholder(placeholder).fill(escaped);
        } else if (selector) {
          await page.fill(selector, escaped);
        } else {
          return { id, success: false, error: '需要 selector、label 或 placeholder' };
        }
        if (press_enter || submit) {
          if (submit && submit_selector) {
            await page.click(submit_selector);
          } else {
            await page.keyboard.press('Enter');
          }
          await page.waitForLoadState('domcontentloaded');
        }
        return { id, success: true, url: page.url(), title: await page.title(), message: '已填写表单' };
      }

      // === 打字 ===
      case 'type': {
        await ensureBrowser(args);
        const { selector, text = '', delay = 50 } = args;
        if (selector) {
          await page.type(selector, escapeJs(text), { delay });
        } else {
          await page.keyboard.type(escapeJs(text), { delay });
        }
        return { id, success: true, message: '已输入文本' };
      }

      // === 悬停 ===
      case 'hover': {
        await ensureBrowser(args);
        const { selector, position } = args;
        if (position) {
          await page.mouse.move(position.x, position.y);
        } else if (selector) {
          await page.hover(selector);
        } else {
          return { id, success: false, error: '需要 selector 或 position' };
        }
        return { id, success: true, message: '已悬停' };
      }

      // === 滚动 ===
      case 'scroll': {
        await ensureBrowser(args);
        const { direction = 'down', distance = 500, selector, to_bottom } = args;
        if (selector) {
          await page.locator(selector).scrollIntoViewIfNeeded();
        } else if (to_bottom) {
          await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
        } else {
          await page.evaluate(() => window.scrollBy(0, direction === 'up' ? -distance : distance));
        }
        await page.waitForTimeout(300);
        const scrollY = await page.evaluate(() => window.scrollY);
        return { id, success: true, scroll_position: scrollY };
      }

      // === 截图 ===
      case 'screenshot': {
        await ensureBrowser(args);
        const { output_path, selector, full_page = true } = args;
        const screenshotPath = output_path || path.join(process.cwd(), `screenshot_${Date.now()}.png`);
        if (selector) {
          const el = await page.$(selector);
          if (!el) return { id, success: false, error: '元素未找到' };
          await el.screenshot({ path: screenshotPath });
        } else {
          await page.screenshot({ path: screenshotPath, fullPage: full_page });
        }
        return { id, success: true, screenshot_path: screenshotPath, message: '截图已保存' };
      }

      // === 数据抓取 ===
      case 'scrape': {
        await ensureBrowser(args);
        const { selectors, selector, attribute, multiple, extract_links, extract_text } = args;
        if (selectors && selectors.length > 0) {
          const results = {};
          for (const sel of selectors) {
            results[sel] = await page.$$(sel).then(els => Promise.all(els.map(el => el.textContent())));
          }
          return { id, success: true, data: results };
        } else if (selector) {
          if (multiple) {
            const elements = await page.$$(selector);
            const results = await Promise.all(elements.map(el =>
              attribute ? el.getAttribute(attribute) : el.textContent()
            ));
            return { id, success: true, data: results.filter(Boolean) };
          } else {
            const el = await page.$(selector);
            const result = el ? (attribute ? await el.getAttribute(attribute) : await el.textContent()) : null;
            return { id, success: true, data: result };
          }
        } else if (extract_text) {
          const text = await page.evaluate(() => document.body.innerText);
          return { id, success: true, title: await page.title(), text };
        } else if (extract_links) {
          const links = await page.evaluate(() => {
            return Array.from(document.querySelectorAll('a')).map(a => ({
              text: a.textContent?.trim(),
              href: a.href,
            })).filter(l => l.text && l.href);
          });
          return { id, success: true, links };
        } else {
          const content = await page.content();
          return { id, success: true, title: await page.title(), html_length: content.length };
        }
      }

      // === 下拉选择 ===
      case 'select': {
        await ensureBrowser(args);
        const { selector = '', value, label, index } = args;
        if (value) {
          await page.selectOption(selector, value);
        } else if (label) {
          await page.selectOption(selector, { label });
        } else if (index !== undefined) {
          await page.selectOption(selector, { index });
        } else {
          return { id, success: false, error: '需要 value、label 或 index' };
        }
        return { id, success: true, message: '已选择选项' };
      }

      // === 等待 ===
      case 'wait': {
        await ensureBrowser(args);
        const { selector, time, until, url: waitForUrl, text } = args;
        if (time) {
          await page.waitForTimeout(time);
        } else if (selector) {
          await page.waitForSelector(selector, { state: args.state || 'visible', timeout: args.timeout || 30000 });
        } else if (text) {
          await page.waitForSelector(`text=${text}`, { timeout: args.timeout || 30000 });
        } else if (waitForUrl) {
          await page.waitForURL(waitForUrl, { timeout: args.timeout || 30000 });
        } else if (until) {
          await page.waitForLoadState(until);
        } else {
          await page.waitForLoadState('networkidle');
        }
        return { id, success: true, message: '等待完成' };
      }

      // === 键盘 ===
      case 'keyboard': {
        await ensureBrowser(args);
        const { key, keys, modifier, text, delay = 50 } = args;
        if (key) {
          await page.keyboard.press(modifier ? `${modifier}+${key}` : key);
        } else if (keys) {
          for (const k of keys.split(',')) {
            await page.keyboard.press(k.trim());
          }
        } else if (text) {
          await page.keyboard.type(text, { delay });
        } else {
          return { id, success: false, error: '需要 key、keys 或 text' };
        }
        return { id, success: true, message: '键盘操作完成' };
      }

      // === 鼠标 ===
      case 'mouse': {
        await ensureBrowser(args);
        const { mouse_action, x, y, button = 'left', click_count = 1 } = args;
        if (mouse_action === 'move' && x != null && y != null) {
          await page.mouse.move(x, y);
        } else if (mouse_action === 'click' && x != null && y != null) {
          await page.mouse.click(x, y, { button, clickCount: click_count });
        } else if (mouse_action === 'down') {
          await page.mouse.down({ button });
        } else if (mouse_action === 'up') {
          await page.mouse.up({ button });
        } else if (mouse_action === 'wheel' && x != null && y != null) {
          await page.mouse.wheel(x, y);
        } else {
          return { id, success: false, error: '需要有效的鼠标操作' };
        }
        return { id, success: true, message: '鼠标操作完成' };
      }

      // === 拖拽 ===
      case 'drag': {
        await ensureBrowser(args);
        const { source, target, source_position, target_position } = args;
        if (source && target) {
          await page.dragAndDrop(source, target);
        } else if (source_position && target_position) {
          await page.mouse.move(source_position.x, source_position.y);
          await page.mouse.down();
          await page.mouse.move(target_position.x, target_position.y);
          await page.mouse.up();
        } else {
          return { id, success: false, error: '需要 source/target 或 source_position/target_position' };
        }
        return { id, success: true, message: '拖拽完成' };
      }

      // === iframe ===
      case 'iframe': {
        await ensureBrowser(args);
        const { iframe_selector, sub_action, sub_args = {} } = args;
        if (!iframe_selector) return { id, success: false, error: '需要 iframe_selector' };
        const frame = page.frameLocator(iframe_selector);
        if (sub_action === 'click') {
          await frame.locator(sub_args.selector).click();
        } else if (sub_action === 'fill') {
          await frame.locator(sub_args.selector).fill(sub_args.value || '');
        } else if (sub_action === 'scrape') {
          const content = await frame.locator(sub_args.selector || 'body').textContent();
          return { id, success: true, data: content };
        }
        return { id, success: true, message: '已定位到 iframe' };
      }

      // === Cookie ===
      case 'cookies': {
        await ensureBrowser(args);
        const { cookie_action } = args;
        if (cookie_action === 'clear') {
          await context.clearCookies();
          return { id, success: true, message: '已清除所有 Cookie' };
        } else if (cookie_action === 'set' && args.cookies) {
          let cookies = args.cookies;
          if (typeof cookies === 'string') { try { cookies = JSON.parse(cookies); } catch (_) {} }
          if (Array.isArray(cookies)) await context.addCookies(cookies);
          return { id, success: true, message: '已设置 Cookie' };
        } else {
          const cookies = await context.cookies();
          return { id, success: true, cookies };
        }
      }

      // === 执行 JS ===
      case 'evaluate': {
        await ensureBrowser(args);
        const result = await page.evaluate(new Function('return ' + args.script)());
        return { id, success: true, result };
      }

      // === PDF ===
      case 'pdf': {
        await ensureBrowser(args);
        const pdfPath = args.output_path || path.join(process.cwd(), `page_${Date.now()}.pdf`);
        await page.pdf({ path: pdfPath, format: args.format || 'A4', printBackground: true });
        return { id, success: true, pdf_path: pdfPath, message: 'PDF 已生成' };
      }

      // === 多步骤 ===
      case 'multi': {
        await ensureBrowser(args);
        const { steps = [] } = args;
        const results = [];
        for (let i = 0; i < steps.length; i++) {
          const step = steps[i];
          switch (step.action) {
            case 'navigate':
              await page.goto(step.url, { waitUntil: step.wait_until || 'domcontentloaded' });
              break;
            case 'click':
              await page.click(step.selector);
              if (step.wait_for) await page.waitForSelector(step.wait_for);
              break;
            case 'fill':
              await page.fill(step.selector, step.value || '');
              break;
            case 'type':
              await page.type(step.selector || '', step.text || '');
              break;
            case 'wait':
              if (step.time) await page.waitForTimeout(step.time);
              else if (step.selector) await page.waitForSelector(step.selector);
              break;
            case 'hover':
              await page.hover(step.selector);
              break;
            case 'scroll':
              await page.evaluate(() => window.scrollBy(0, step.distance || 500));
              break;
            case 'screenshot':
              await page.screenshot({ path: step.output_path || `step_${i + 1}.png` });
              break;
            case 'keyboard':
              await page.keyboard.press(step.key);
              break;
          }
          results.push({ step: i + 1, action: step.action, status: 'completed' });
        }
        return { id, success: true, title: await page.title(), url: page.url(), steps_completed: results.length, results };
      }

      // === 上传 ===
      case 'upload': {
        await ensureBrowser(args);
        const { selector = '', files = [] } = args;
        if (!files.length) return { id, success: false, error: '需要 files' };
        await page.setInputFiles(selector, files);
        return { id, success: true, message: `已上传 ${files.length} 个文件` };
      }

      // === 下载 ===
      case 'download': {
        await ensureBrowser(args);
        const { download_selector, url, save_path } = args;
        if (download_selector) {
          const [download] = await Promise.all([
            page.waitForEvent('download'),
            page.click(download_selector),
          ]);
          const downloadPath = save_path || path.join(process.cwd(), download.suggestedFilename());
          await download.saveAs(downloadPath);
          return { id, success: true, download_path: downloadPath };
        } else if (url) {
          const response = await page.request.get(url);
          const downloadPath = save_path || path.join(process.cwd(), `download_${Date.now()}`);
          await response.body().then(body => fs.writeFileSync(downloadPath, body));
          return { id, success: true, download_path: downloadPath };
        }
        return { id, success: false, error: '需要 download_selector 或 url' };
      }

      default:
        return { id, success: false, error: `未知操作: ${action}` };
    }
  } catch (error) {
    return { id, success: false, error: error.message };
  }
}

// 确保浏览器已启动
async function ensureBrowser(args = {}) {
  if (!browser) {
    browser = await chromium.launch({ headless: args.headless !== undefined ? args.headless : false, slowMo: args.slow_mo || 0 });
    context = await browser.newContext({
      viewport: { width: args.viewport_width || 1920, height: args.viewport_height || 1080 },
    });
    page = await context.newPage();
    page.setDefaultTimeout(args.timeout || 30000);
  }
  return page;
}

// 转义 JS 字符串中的特殊字符
function escapeJs(input) {
  if (typeof input !== 'string') return String(input);
  return input
    .replace(/\\/g, '\\\\')
    .replace(/'/g, "\\'")
    .replace(/\n/g, '\\n')
    .replace(/\r/g, '\\r')
    .replace(/\t/g, '\\t');
}

// === 主循环：从 stdin 读取 JSON 指令 ===
let inputBuffer = '';
let cmdId = 0;

process.stdin.setEncoding('utf8');
process.stdin.on('data', async (chunk) => {
  inputBuffer += chunk;
  
  // 按行分割处理
  const lines = inputBuffer.split('\n');
  inputBuffer = lines.pop(); // 保留最后一个可能不完整的行
  
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    
    try {
      const cmd = JSON.parse(trimmed);
      const response = await handleCommand(cmd);
      process.stdout.write(JSON.stringify(response) + '\n');
    } catch (e) {
      const errorMsg = { id: cmdId++, success: false, error: e.message };
      process.stdout.write(JSON.stringify(errorMsg) + '\n');
    }
  }
});

process.stdin.on('end', () => {
  // stdin 关闭，清理退出
  if (browser) {
    browser.close().catch(() => {}).then(() => process.exit(0));
  } else {
    process.exit(0);
  }
});

process.stderr.on('error', () => {});

// 空闲超时：30 分钟无操作自动关闭浏览器（保留进程）
let idleTimer = null;
function resetIdleTimer() {
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = setTimeout(async () => {
    if (browser) {
      try { await Promise.race([browser.close(), new Promise(r => setTimeout(r, 5000))]); } catch (_) {}
      browser = null; context = null; page = null;
      process.stderr.write('[Playwright Server] 空闲超时，浏览器已关闭\n');
    }
  }, 30 * 60 * 1000);
}
resetIdleTimer();

// 每次收到指令重置空闲计时
process.stdin.on('data', resetIdleTimer);
