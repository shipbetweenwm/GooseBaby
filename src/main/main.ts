import { app, BrowserWindow, Tray, Menu, ipcMain, screen, nativeImage, globalShortcut } from 'electron'
import * as path from 'path'
import { LLMManager } from './ai/llm-manager'
import { SkillManager } from './skills/skill-manager'
import { PetEngine } from './engine/pet-engine'
import { MemoryManager } from './ai/memory-manager'

// ============================================
// 鹅宝 - GooseBaby Desktop AI Pet
// Electron 主进程
// ============================================

let petWindow: BrowserWindow | null = null
let chatWindow: BrowserWindow | null = null
let tray: Tray | null = null
let llmManager: LLMManager
let skillManager: SkillManager
let petEngine: PetEngine
let memoryManager: MemoryManager

const isDev = process.argv.includes('--dev') || !app.isPackaged

// ---- 创建宠物窗口（透明悬浮） ----
function createPetWindow() {
  const { width: screenWidth, height: screenHeight } = screen.getPrimaryDisplay().workAreaSize

  petWindow = new BrowserWindow({
    width: 200,
    height: 200,
    x: screenWidth - 250,
    y: screenHeight - 250,
    transparent: true,
    frame: false,
    resizable: false,
    alwaysOnTop: true,
    hasShadow: false,
    skipTaskbar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })

  // 允许鼠标穿透非内容区域
  petWindow.setIgnoreMouseEvents(false)
  petWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: false })

  if (isDev) {
    petWindow.loadURL('http://localhost:5173/pet.html')
  } else {
    petWindow.loadFile(path.join(__dirname, '../renderer/pet.html'))
  }

  petWindow.on('closed', () => {
    petWindow = null
  })
}

// ---- 创建聊天窗口 ----
function createChatWindow() {
  if (chatWindow) {
    chatWindow.show()
    chatWindow.focus()
    return
  }

  const { width: screenWidth, height: screenHeight } = screen.getPrimaryDisplay().workAreaSize

  chatWindow = new BrowserWindow({
    width: 420,
    height: 600,
    x: screenWidth - 480,
    y: screenHeight - 650,
    frame: false,
    resizable: true,
    transparent: false,
    backgroundColor: '#ffffff',
    alwaysOnTop: true,
    skipTaskbar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })

  if (isDev) {
    chatWindow.loadURL('http://localhost:5173/chat.html')
  } else {
    chatWindow.loadFile(path.join(__dirname, '../renderer/chat.html'))
  }

  chatWindow.once('ready-to-show', () => {
    chatWindow?.show()
  })

  chatWindow.on('closed', () => {
    chatWindow = null
  })
}

// ---- 创建系统托盘 ----
function createTray() {
  // 使用简单的 emoji 作为托盘图标（生产环境用真实图标）
  const icon = nativeImage.createFromDataURL(
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAGHSURBVFhH7ZY9TsMwFMf/TtqhE0tXLsDCyMrABbgBN+AGcAM4A2dgZmRl6cLExkpVtet7dmI7iZ20BosnyZL9Pv7v+dlJ+48opSb8kxhFAH4VZcUZX0CW8/2M76FfUuaPoJNguQfKAqg3gPoN0GDz4kGYwWNEgUlwJwCTAFhUbm3F4e7x/fvN+K8qAn5G8wLQqyNw7fLu9Xlx3J73LPvADN7YAq/FUcRsJP3F5g7gDUE3QZYhQQVE3Q1gCoiaGvA3hBUTdDVAbwi6OoA7RDUT1AWYb0SdHUAFUPgVhB0bYB+iDIhqAegngdGCbg7AD2AtAmIkKA+IWiDoQ2CNgg4IuiJoMoA9gFUE7RCUEQT0CpCTo5gCsE3RyAF8IuiqADwRdHcAHgq4O4AVBF4fwk2CpiS37j8AHgu4O4CVBU0fQBIH3AvSJ0LNDkP0idHf8qCAJj+q+9AOR4E+M/gpFQL8KrQQJPqBOOFk+FcYBOgf0dHwBqNlb7xeQcgAAAABJRU5ErkJggg=='
  )
  tray = new Tray(icon)

  const contextMenu = Menu.buildFromTemplate([
    {
      label: '🐤 显示鹅宝',
      click: () => petWindow?.show(),
    },
    {
      label: '💬 打开聊天',
      click: () => createChatWindow(),
    },
    { type: 'separator' },
    {
      label: '⚙️ 设置',
      click: () => createChatWindow(), // TODO: 打开设置页
    },
    {
      label: '😴 让鹅宝休息',
      click: () => petWindow?.hide(),
    },
    { type: 'separator' },
    {
      label: '❌ 退出鹅宝',
      click: () => {
        app.quit()
      },
    },
  ])

  tray.setToolTip('鹅宝 - 你的桌面 AI 伙伴')
  tray.setContextMenu(contextMenu)

  tray.on('click', () => {
    if (petWindow?.isVisible()) {
      createChatWindow()
    } else {
      petWindow?.show()
    }
  })
}

// ---- 注册 IPC 通信 ----
function registerIPC() {
  // --- AI 对话 ---
  ipcMain.handle('llm:chat', async (_event, messages: any[], options?: any) => {
    try {
      const response = await llmManager.chat(messages, options)
      return { success: true, data: response }
    } catch (err: any) {
      return { success: false, error: err.message }
    }
  })

  // --- AI 流式对话 ---
  ipcMain.on('llm:chat-stream', async (event, messages: any[], options?: any) => {
    try {
      await llmManager.chatStream(messages, (chunk: string) => {
        event.reply('llm:chat-stream-chunk', chunk)
      }, options)
      event.reply('llm:chat-stream-done')
    } catch (err: any) {
      event.reply('llm:chat-stream-error', err.message)
    }
  })

  // --- 获取/设置模型配置 ---
  ipcMain.handle('llm:get-config', () => {
    return llmManager.getConfig()
  })

  ipcMain.handle('llm:set-config', (_event, config: any) => {
    llmManager.setConfig(config)
    return { success: true }
  })

  ipcMain.handle('llm:get-providers', () => {
    return llmManager.getAvailableProviders()
  })

  // --- 技能系统 ---
  ipcMain.handle('skill:execute', async (_event, skillName: string, params: any) => {
    try {
      const result = await skillManager.execute(skillName, params)
      return { success: true, data: result }
    } catch (err: any) {
      return { success: false, error: err.message }
    }
  })

  ipcMain.handle('skill:list', () => {
    return skillManager.listSkills()
  })

  ipcMain.handle('skill:get-tools', () => {
    return skillManager.getToolDefinitions()
  })

  // --- 记忆系统 ---
  ipcMain.handle('memory:save', async (_event, content: string, metadata?: any) => {
    return memoryManager.save(content, metadata)
  })

  ipcMain.handle('memory:search', async (_event, query: string, limit?: number) => {
    return memoryManager.search(query, limit)
  })

  ipcMain.handle('memory:get-profile', () => {
    return memoryManager.getUserProfile()
  })

  // --- 宠物引擎 ---
  ipcMain.handle('pet:get-state', () => {
    return petEngine.getState()
  })

  ipcMain.handle('pet:interact', (_event, action: string) => {
    return petEngine.interact(action)
  })

  ipcMain.handle('pet:feed', (_event, food: string) => {
    return petEngine.feed(food)
  })

  // --- 窗口控制 ---
  ipcMain.on('window:open-chat', () => {
    createChatWindow()
  })

  ipcMain.on('window:close-chat', () => {
    chatWindow?.close()
  })

  ipcMain.on('pet:move', (_event, x: number, y: number) => {
    petWindow?.setPosition(Math.round(x), Math.round(y))
  })
}

// ---- 应用生命周期 ----
app.whenReady().then(async () => {
  // 初始化核心模块
  llmManager = new LLMManager()
  skillManager = new SkillManager()
  petEngine = new PetEngine()
  memoryManager = new MemoryManager()

  createPetWindow()
  createTray()
  registerIPC()

  // 注册全局快捷键: Option+Space 唤起聊天
  globalShortcut.register('Alt+Space', () => {
    createChatWindow()
  })

  // 启动宠物行为引擎
  petEngine.start((state) => {
    petWindow?.webContents.send('pet:state-update', state)
  })

  console.log('🐤 鹅宝已启动！')
})

app.on('window-all-closed', () => {
  // macOS 下不退出
})

app.on('will-quit', () => {
  globalShortcut.unregisterAll()
})

app.on('activate', () => {
  if (!petWindow) {
    createPetWindow()
  }
})
