const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ 
    headless: false,
    slowMo: 500
  });
  
  const context = await browser.newContext();
  
  // 注入 cookies
  const cookies = [
    { name: 'ts_uid', value: '2317249190', domain: 'wedata.woa.com', path: '/' },
    { name: 'pgv_pvid', value: '1195964675', domain: 'wedata.woa.com', path: '/' },
    { name: 'ERP_USERNAME', value: 'deanjiang', domain: 'wedata.woa.com', path: '/' },
    { name: 'wsd_ulog', value: '6f7b3460a13525cdd6e418bdfc565fd4', domain: 'wedata.woa.com', path: '/' },
    { name: 'RIO_TOKEN', value: '0.tcfn9z.atEotorblHhiZKN7LBpR7oial_tZ7v309610wBdPj3F719ZDhA_RB95KF6RQAZh6RKml-QUzqVpsqT06wHJAijpleCYAHVuThhdxE0xGlyfS67fodyMBC2Yk2rpUm-kJR4i2Vl9pdRgUJhpj3AjOL4diGuPX_wu9BwfhBY0OF9GGLhEmbDCghoEoxcLaU6oAWFFksTKam6RodhjkaYt9_5XbNqv2X6BPvBX95UkXLX-7UtsvoiGsu_eSHMCgbqjkGihDqb5p5YTmMk_liJ3oNsBCyu0YZl-SjjlKQF-xMtLsQ2ZKPa4WjQCoD_724Q2MckGem65IERtpIduYIQRaYFkGikPXwaGiVGzZDCBaf_NwXynQguw8PDLoSb0xm3vr8WnfJ6siLW_43wxJ3rr9awKaUQ52ujupKzhMApuLChR3XoiYk1jeTYLwOVppvwiOMGymD5TH2YrflUz4oJJO-K-uTTpAJDL-jbDy05oi8kDytJMjwftYAaNfDTzc2htfg42Ly1iZpPhnav0HNi_nYSQstdmbdSBbT3k6JMqBz64O0B0DQcefkpmSxs0p7CZkrhkmMWcIv9aM11da_yfZWnNKjxJ5oTf8CYR7XvwAXC96qR-uxX8.NCEjTku0t9FCXamyZMSWKg', domain: 'wedata.woa.com', path: '/' },
    { name: 'RIO_TOKEN_HTTPS', value: '0.tcfn9z.atEotorblHhiZKN7LBpR7oial_tZ7v309610wBdPj3F719ZDhA_RB95KF6RQAZh6RKml-QUzqVpsqT06wHJAijpleCYAHVuThhdxE0xGlyfS67fodyMBC2Yk2rpUm-kJR4i2Vl9pdRgUJhpj3AjOL4diGuPX_wu9BwfhBY0OF9GGLhEmbDCghoEoxcLaU6oAWFFksTKam6RodhjkaYt9_5XbNqv2X6BPvBX95UkXLX-7UtsvoiGsu_eSHMCgbqjkGihDqb5p5YTmMk_liJ3oNsBCyu0YZl-SjjlKQF-xMtLsQ2ZKPa4WjQCoD_724Q2MckGem65IERtpIduYIQRaYFkGikPXwaGiVGzZDCBaf_NwXynQguw8PDLoSb0xm3vr8WnfJ6siLW_43wxJ3rr9awKaUQ52ujupKzhMApuLChR3XoiYk1jeTYLwOVppvwiOMGymD5TH2YrflUz4oJJO-K-uTTpAJDL-jbDy05oi8kDytJMjwftYAaNfDTzc2htfg42Ly1iZpPhnav0HNi_nYSQstdmbdSBbT3k6JMqBz64O0B0DQcefkpmSxs0p7CZkrhkmMWcIv9aM11da_yfZWnNKjxJ5oTf8CYR7XvwAXC96qR-uxX8.NCEjTku0t9FCXamyZMSWKg', domain: 'wedata.woa.com', path: '/' },
    { name: 'pgv_info', value: 'ssid=s2272333738', domain: 'wedata.woa.com', path: '/' },
    { name: 'P_RIO_TOKEN', value: '0.tcfn9z.alEpzwLUPN6ns9wvKFYraSHbfgoe-_2ZPQX90Q2L2t0H_SzAEVEDou5wZnZmOAGeekuZMX9F7tiKCD0hwRsVojFAlEia-N0GcCN45R8ZWXofILxamM5ApUNdvRqerS4crBIww0M14VcSiwn664Un7_FwbGrWbuFeOP_sjQlnLLWPEWrbkXh6721Ljn-twvgHFXKJxkm83zrghYAhGoIDU41SdRezj2HtS4tD1s3LMEnxwZMaGkNne_ZHJ2AvRtSxFWSc6qZUQNJVj4ZDnqhsS_C1Sr24XDa6RHU_KquHhvxBChpSB_gBZI7XZa1eyMYjrCChjB1jLIjwu_pUFOcXV9B9ndcwrSFyMzxudiS41QTXZNYfCiYjWjXN_ykWuee8C_OWjcHyJDlN6Yksa3aLmktl9jkOg21OI5Ws6ysz39RPWWQ24-gLSMHiQLNFsoWkmQndPRmj_k8_aqqhhLCYVIy87P2IefAhiC9yNTNEKh9mQsZifGzkGFPMkfFck9dWSCSDXbc-rn-Urok1s2WoiQKOk_oi64HavpCwD8gojkmDCD11_bdDCQ-9H9raztul3S7SChYERpsLvsQemXJn5_CytWs6obOXqy7KTmy5SovwAbjwZFBqqaoiKiz4eYF1vBt_bcTtPj1rn2eC7eXDNXRjcpy4TI3yU1xhb_IJtOGuP3ZsQOvZYpYeMOWgVt6iiKiAO4zp-w5VHWHIsT9bMjLsPXeCa8CyJdz1_3BxnVd4yuDEeIoSKO-Ki7Vo5Z0cs101bt_bfzrlBihpftp87Jvp0zd3evKwYrRqnWgLy5P-zgSnLYhrz3l0n0G7mrhSvhlbeThfxtX5ncT2uy4hvAXekjdZ1SLDpxNinFDLqQap4QsjcUG1NR14TG5E0tmb2Y2JW2YQOAsXiSw7.9rSGUJlsLvQnyLzRAA25Sw', domain: 'wedata.woa.com', path: '/' },
    { name: 'monitor_et_user', value: 'deanjiang', domain: 'wedata.woa.com', path: '/' },
    { name: 'Hybris-Center-TdwMeta', value: '13DD8EBEC8FF127A03B293E4642E2260', domain: 'wedata.woa.com', path: '/' },
    { name: 'x-client-ssid', value: '66622415:019d242780a2:18b2d7', domain: 'wedata.woa.com', path: '/' },
    { name: 'ts_last', value: 'wedata.woa.com/explore/file/0e07f162f4d04372a8e82855cc1763d8', domain: 'wedata.woa.com', path: '/' }
  ];
  
  await context.addCookies(cookies);
  
  const page = await context.newPage();
  
  // 访问 WeData 数据探索页面
  console.log('正在访问 WeData 数据探索页面...');
  await page.goto('https://wedata.woa.com/explore/file/0e07f162f4d04372a8e82855cc1763d8?fileSpaceCode=0', {
    waitUntil: 'networkidle'
  });
  
  // 等待页面加载
  await page.waitForTimeout(3000);
  
  // 截图
  await page.screenshot({ path: 'wedata_page.png', fullPage: true });
  console.log('页面截图已保存到 wedata_page.png');
  
  // 等待用户操作
  console.log('\n浏览器已打开，请在浏览器中手动操作：');
  console.log('1. 如果需要登录，请完成登录');
  console.log('2. 在 SQL 编辑器中执行 DESC sec_yd_t_win_new_proc_info');
  console.log('3. 执行 SELECT * FROM sec_yd_t_win_new_proc_info LIMIT 100');
  console.log('4. 查看结果后按 Ctrl+C 退出');
  
  // 保持浏览器打开
  await page.waitForTimeout(600000); // 10 分钟
  
  await browser.close();
})();
