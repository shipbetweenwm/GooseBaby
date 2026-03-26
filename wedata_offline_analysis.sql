-- ============================================================
-- WeData 离线数据分析：Windows 入侵检测策略验证
-- 表名：yd_onion_interface.sec_yd_t_win_new_proc_info
-- 分区字段：tdbank_imp_date
-- 创建时间：2026-03-25
-- ============================================================

-- ============================================================
-- PART 1: 表结构探索与数据采样
-- ============================================================

-- 1.1 查看表结构（如果支持 DESC）
-- DESC yd_onion_interface.sec_yd_t_win_new_proc_info;

-- 1.2 数据采样 - 查看最近一天的数据样本
SELECT *
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
LIMIT 100;

-- 1.3 查看所有字段名（通过第一条记录）
SELECT *
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
LIMIT 1;

-- 1.4 统计总记录数
SELECT 
    '总记录数' AS metric,
    COUNT(*) AS value
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319';

-- 1.5 查看可用分区
SELECT DISTINCT tdbank_imp_date
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
ORDER BY tdbank_imp_date DESC
LIMIT 30;


-- ============================================================
-- PART 2: 字段统计分析
-- ============================================================

-- 2.1 进程路径分布 Top 50
SELECT 
    proc_fullpath,
    COUNT(*) AS cnt
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
GROUP BY proc_fullpath
ORDER BY cnt DESC
LIMIT 50;

-- 2.2 进程名分布 Top 50
SELECT 
    proc_name,
    COUNT(*) AS cnt
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
GROUP BY proc_name
ORDER BY cnt DESC
LIMIT 50;

-- 2.3 父进程名分布 Top 30
SELECT 
    proc_parent_name,
    COUNT(*) AS cnt
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
GROUP BY proc_parent_name
ORDER BY cnt DESC
LIMIT 30;

-- 2.4 主机分布 Top 30
SELECT 
    host_ip,
    host_name,
    COUNT(*) AS cnt
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
GROUP BY host_ip, host_name
ORDER BY cnt DESC
LIMIT 30;

-- 2.5 用户分布 Top 30
SELECT 
    user_name,
    COUNT(*) AS cnt
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
GROUP BY user_name
ORDER BY cnt DESC
LIMIT 30;


-- ============================================================
-- PART 3: Windows 入侵检测策略 - 离线验证
-- ============================================================

-- ============================================================
-- 策略 1: 可疑进程路径检测
-- 检测从非标准路径启动的系统进程
-- ============================================================

SELECT 
    '策略1-可疑路径进程' AS alert_type,
    host_ip,
    host_name,
    proc_name,
    proc_fullpath,
    user_name,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_name IN (
    'cmd.exe', 'powershell.exe', 'powershell_ise.exe',
    'rundll32.exe', 'regsvr32.exe', 'mshta.exe',
    'wscript.exe', 'cscript.exe', 'certutil.exe',
    'bitsadmin.exe', 'msiexec.exe', 'svchost.exe',
    'lsass.exe', 'csrss.exe', 'winlogon.exe', 'wininit.exe',
    'services.exe', 'smss.exe', 'taskmgr.exe', 'mmc.exe'
  )
  AND proc_fullpath IS NOT NULL
  AND (
    -- 不在标准 Windows 目录
    proc_fullpath NOT LIKE '%\\Windows\\System32\\%'
    AND proc_fullpath NOT LIKE '%\\Windows\\SysWOW64\\%'
    AND proc_fullpath NOT LIKE '%\\Windows\\System32%'
    -- 在可疑位置
    AND (
      proc_fullpath LIKE '%\\Temp\\%'
      OR proc_fullpath LIKE '%\\AppData\\%'
      OR proc_fullpath LIKE '%\\Public\\%'
      OR proc_fullpath LIKE '%\\ProgramData\\%'
      OR proc_fullpath LIKE '%\\Users\\%'
      OR proc_fullpath LIKE '%\\PerfLogs\\%'
      OR proc_fullpath LIKE '%\\Program Files\\%'
      OR proc_fullpath LIKE 'C:\\%'
    )
  )
GROUP BY host_ip, host_name, proc_name, proc_fullpath, user_name
ORDER BY alert_count DESC
LIMIT 100;


-- ============================================================
-- 策略 2: 危险命令行参数检测
-- 检测包含危险参数的命令行
-- ============================================================

SELECT 
    '策略2-危险命令行' AS alert_type,
    host_ip,
    host_name,
    proc_name,
    proc_cmdline,
    user_name,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_cmdline IS NOT NULL
  AND (
    -- PowerShell 危险参数
    (proc_name = 'powershell.exe' AND (
      proc_cmdline LIKE '%-EncodedCommand%' 
      OR proc_cmdline LIKE '%-enc%'
      OR proc_cmdline LIKE '%-e%'
      OR proc_cmdline LIKE '%-WindowStyle Hidden%'
      OR proc_cmdline LIKE '%-w hidden%'
      OR proc_cmdline LIKE '%-ExecutionPolicy Bypass%'
      OR proc_cmdline LIKE '%-ep bypass%'
      OR proc_cmdline LIKE '%-NoProfile%'
      OR proc_cmdline LIKE '%DownloadString%'
      OR proc_cmdline LIKE '%DownloadFile%'
      OR proc_cmdline LIKE '%Invoke-WebRequest%'
      OR proc_cmdline LIKE '%IEX%'
      OR proc_cmdline LIKE '%Invoke-Expression%'
      OR proc_cmdline LIKE '%[Convert]::FromBase64String%'
      OR proc_cmdline LIKE '%[Net.WebClient]%'
    ))
    -- CMD 危险命令
    OR (proc_name = 'cmd.exe' AND (
      proc_cmdline LIKE '%certutil%urlcache%'
      OR proc_cmdline LIKE '%certutil%-decode%'
      OR proc_cmdline LIKE '%bitsadmin%/transfer%'
      OR proc_cmdline LIKE '%reg add%'
      OR proc_cmdline LIKE '%reg delete%'
      OR proc_cmdline LIKE '%net user%'
      OR proc_cmdline LIKE '%net localgroup%'
      OR proc_cmdline LIKE '%wmic%'
    ))
    -- Certutil 下载
    OR (proc_name = 'certutil.exe' AND (
      proc_cmdline LIKE '%-urlcache%'
      OR proc_cmdline LIKE '%-decode%'
      OR proc_cmdline LIKE '%-verifyctl%'
    ))
    -- Mshta 执行远程脚本
    OR (proc_name = 'mshta.exe' AND (
      proc_cmdline LIKE '%http://%'
      OR proc_cmdline LIKE '%https://%'
      OR proc_cmdline LIKE '%.hta%'
    ))
    -- Rundll32 执行可疑 DLL
    OR (proc_name = 'rundll32.exe' AND (
      proc_cmdline LIKE '%javascript:%'
      OR proc_cmdline LIKE '%vbscript:%'
      OR proc_cmdline LIKE '%\\Temp\\%'
      OR proc_cmdline LIKE '%\\AppData\\%'
      OR proc_cmdline LIKE '%url.dll%'
      OR proc_cmdline LIKE '%zipfldr.dll%'
    ))
    -- Regsvr32 远程执行
    OR (proc_name = 'regsvr32.exe' AND (
      proc_cmdline LIKE '%http://%'
      OR proc_cmdline LIKE '%https://%'
      OR proc_cmdline LIKE '%/s /n /u%'
      OR proc_cmdline LIKE '%scrobj.dll%'
    ))
    -- WMI 远程执行
    OR (proc_name = 'wmic.exe' AND (
      proc_cmdline LIKE '%node:%'
      OR proc_cmdline LIKE '%process call create%'
    ))
  )
GROUP BY host_ip, host_name, proc_name, proc_cmdline, user_name
ORDER BY alert_count DESC
LIMIT 100;


-- ============================================================
-- 策略 3: 异常父子进程关系检测
-- 检测不应该出现的父子进程关系
-- ============================================================

SELECT 
    '策略3-异常父子进程' AS alert_type,
    host_ip,
    host_name,
    proc_parent_name,
    proc_name,
    proc_fullpath,
    proc_cmdline,
    user_name,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_parent_name IS NOT NULL
  AND (
    -- Office 程序启动命令行/脚本
    (proc_parent_name IN ('WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE', 'OUTLOOK.EXE', 'MSACCESS.EXE')
     AND proc_name IN ('cmd.exe', 'powershell.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'rundll32.exe'))
    
    -- 记事本/计算器等简单程序启动可疑进程
    OR (proc_parent_name IN ('notepad.exe', 'calc.exe', 'wordpad.exe', 'mspaint.exe', 'write.exe')
        AND proc_name IN ('cmd.exe', 'powershell.exe', 'wscript.exe', 'cscript.exe'))
    
    -- 浏览器启动系统进程
    OR (proc_parent_name IN ('chrome.exe', 'firefox.exe', 'iexplore.exe', 'msedge.exe', '360se.exe', 'qqbrowser.exe')
        AND proc_name IN ('cmd.exe', 'powershell.exe', 'wscript.exe', 'cscript.exe'))
    
    -- svchost.exe 不应该启动 cmd/powershell
    OR (proc_parent_name = 'svchost.exe' AND proc_name IN ('cmd.exe', 'powershell.exe'))
    
    -- lsass.exe 不应该启动任何进程
    OR (proc_parent_name = 'lsass.exe')
    
    -- 服务进程启动可疑程序
    OR (proc_parent_name = 'services.exe' 
        AND proc_name IN ('cmd.exe', 'powershell.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe'))
  )
GROUP BY host_ip, host_name, proc_parent_name, proc_name, proc_fullpath, proc_cmdline, user_name
ORDER BY alert_count DESC
LIMIT 100;


-- ============================================================
-- 策略 4: 横向移动检测
-- 检测远程执行和横向移动相关进程
-- ============================================================

SELECT 
    '策略4-横向移动' AS alert_type,
    host_ip,
    host_name,
    proc_name,
    proc_fullpath,
    proc_cmdline,
    user_name,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND (
    -- PsExec 远程执行
    proc_name IN ('psexec.exe', 'psexec64.exe', 'PAExec.exe')
    OR (proc_name = 'psexesvc.exe')
    
    -- WMI 远程
    OR (proc_name = 'wmiprvse.exe' AND proc_cmdline IS NOT NULL 
        AND (proc_cmdline LIKE '%-node:%' OR proc_cmdline LIKE '%process call create%'))
    
    -- 远程服务创建
    OR (proc_name = 'sc.exe' AND proc_cmdline IS NOT NULL 
        AND proc_cmdline LIKE '%\\\\%')
    
    -- SMB 远程执行
    OR (proc_name = 'cmd.exe' AND proc_cmdline IS NOT NULL 
        AND proc_cmdline LIKE '%\\\\%\\c$%')
    
    -- 远程注册表
    OR (proc_name = 'reg.exe' AND proc_cmdline IS NOT NULL 
        AND proc_cmdline LIKE '%\\\\%')
    
    -- WMI 远程执行
    OR (proc_name = 'wmic.exe' AND proc_cmdline IS NOT NULL 
        AND proc_cmdline LIKE '%/node:%')
    
    -- 远程桌面相关
    OR proc_name IN ('mstsc.exe', 'vnc.exe', 'teamviewer.exe', 'anydesk.exe')
    
    -- Mimikatz 相关
    OR (proc_name = 'mimikatz.exe' OR proc_fullpath LIKE '%mimikatz%')
    OR (proc_cmdline IS NOT NULL AND (
        proc_cmdline LIKE '%sekurlsa::logonpasswords%'
        OR proc_cmdline LIKE '%lsadump::dcsync%'
        OR proc_cmdline LIKE '%privilege::debug%'
    ))
  )
GROUP BY host_ip, host_name, proc_name, proc_fullpath, proc_cmdline, user_name
ORDER BY alert_count DESC
LIMIT 100;


-- ============================================================
-- 策略 5: 持久化检测
-- 检测注册表、计划任务、服务等持久化行为
-- ============================================================

SELECT 
    '策略5-持久化' AS alert_type,
    host_ip,
    host_name,
    proc_name,
    proc_fullpath,
    proc_cmdline,
    user_name,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_cmdline IS NOT NULL
  AND (
    -- 注册表自启动项修改
    (proc_cmdline LIKE '%reg add%HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run%')
    OR (proc_cmdline LIKE '%reg add%HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run%')
    
    -- 计划任务创建
    OR (proc_name = 'schtasks.exe' AND (
        proc_cmdline LIKE '%/create%'
        OR proc_cmdline LIKE '%/change%'
    ))
    
    -- 服务创建
    OR (proc_name = 'sc.exe' AND proc_cmdline LIKE '%create%')
    
    -- WMI 事件订阅持久化
    OR (proc_cmdline LIKE '%__EventToConsumerBinding%')
    OR (proc_cmdline LIKE '%CommandLineEventConsumer%')
    OR (proc_cmdline LIKE '%ActiveScriptEventConsumer%')
    
    -- 启动文件夹
    OR (proc_cmdline LIKE '%\\Start Menu\\Programs\\Startup%')
    
    -- 注册表服务修改
    OR (proc_cmdline LIKE '%reg add%HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services%')
  )
GROUP BY host_ip, host_name, proc_name, proc_fullpath, proc_cmdline, user_name
ORDER BY alert_count DESC
LIMIT 100;


-- ============================================================
-- 策略 6: 权限提升检测
-- 检测提权相关行为
-- ============================================================

SELECT 
    '策略6-权限提升' AS alert_type,
    host_ip,
    host_name,
    proc_name,
    proc_fullpath,
    proc_cmdline,
    user_name,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND (
    -- UAC 绕过相关
    proc_name IN ('fodhelper.exe', 'eventvwr.exe', 'sdclt.exe', 'compmgmtlauncher.exe')
    OR (proc_cmdline IS NOT NULL AND proc_cmdline LIKE '%fodhelper%')
    OR (proc_cmdline IS NOT NULL AND proc_cmdline LIKE '%eventvwr%')
    
    -- RunAs 提权
    OR proc_name = 'runas.exe'
    
    -- 访问 LSASS
    OR (proc_name IN ('procdump.exe', 'procdump64.exe', 'ntdsutil.exe', 'vssadmin.exe')
        OR proc_fullpath LIKE '%procdump%')
    
    -- 访问 SAM/SYSTEM 文件
    OR (proc_cmdline IS NOT NULL AND (
        proc_cmdline LIKE '%\\config\\SAM%'
        OR proc_cmdline LIKE '%\\config\\SYSTEM%'
        OR proc_cmdline LIKE '%ntds.dit%'
    ))
    
    -- 调试权限
    OR (proc_cmdline IS NOT NULL AND proc_cmdline LIKE '%SeDebugPrivilege%')
    
    -- DCSync 相关
    OR (proc_cmdline IS NOT NULL AND proc_cmdline LIKE '%lsadump::dcsync%')
  )
GROUP BY host_ip, host_name, proc_name, proc_fullpath, proc_cmdline, user_name
ORDER BY alert_count DESC
LIMIT 100;


-- ============================================================
-- 策略 7: 数据窃取检测
-- 检测敏感文件访问和数据外传行为
-- ============================================================

SELECT 
    '策略7-数据窃取' AS alert_type,
    host_ip,
    host_name,
    proc_name,
    proc_fullpath,
    proc_cmdline,
    user_name,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_cmdline IS NOT NULL
  AND (
    -- 敏感文件访问
    proc_cmdline LIKE '%password%'
    OR proc_cmdline LIKE '%credential%'
    OR proc_cmdline LIKE '%secret%'
    OR proc_cmdline LIKE '%key%.pfx%'
    OR proc_cmdline LIKE '%key%.p12%'
    
    -- 浏览器数据窃取
    OR proc_cmdline LIKE '%\\AppData\\Local\\Google\\Chrome\\User Data%'
    OR proc_cmdline LIKE '%\\AppData\\Local\\Microsoft\\Edge\\User Data%'
    OR proc_cmdline LIKE '%Login Data%'
    OR proc_cmdline LIKE '%Web Data%'
    OR proc_cmdline LIKE '%cookies.sqlite%'
    
    -- 压缩打包（可能用于数据窃取）
    OR (proc_name IN ('7z.exe', 'winrar.exe', 'rar.exe', 'zip.exe', 'tar.exe')
        AND (proc_cmdline LIKE '%-p%' OR proc_cmdline LIKE '%password%'))
    
    -- FTP 传输
    OR proc_name IN ('ftp.exe', 'winscp.exe', 'filezilla.exe', 'nc.exe', 'ncat.exe')
    
    -- Base64 编码（可能用于数据编码传输）
    OR (proc_name = 'certutil.exe' AND proc_cmdline LIKE '%-encode%')
    
    -- DNS 隧道可疑
    OR (proc_cmdline LIKE '%nslookup%-%')
  )
GROUP BY host_ip, host_name, proc_name, proc_fullpath, proc_cmdline, user_name
ORDER BY alert_count DESC
LIMIT 100;


-- ============================================================
-- 策略 8: 反沙箱/反调试检测
-- 检测恶意软件常用的反分析技术
-- ============================================================

SELECT 
    '策略8-反沙箱' AS alert_type,
    host_ip,
    host_name,
    proc_name,
    proc_fullpath,
    proc_cmdline,
    user_name,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_cmdline IS NOT NULL
  AND (
    -- 虚拟机检测命令
    proc_cmdline LIKE '%systeminfo%'
    OR proc_cmdline LIKE '%wmic bios%'
    OR proc_cmdline LIKE '%wmic baseboard%'
    OR proc_cmdline LIKE '%wmic cpu%'
    OR proc_cmdline LIKE '%vmware%'
    OR proc_cmdline LIKE '%virtualbox%'
    OR proc_cmdline LIKE '%vbox%'
    OR proc_cmdline LIKE '%qemu%'
    
    -- 调试器检测
    OR proc_cmdline LIKE '%IsDebuggerPresent%'
    OR proc_cmdline LIKE '%CheckRemoteDebuggerPresent%'
    
    -- 延时执行
    OR (proc_name = 'timeout.exe' AND proc_cmdline LIKE '%/t%')
    OR (proc_name = 'ping.exe' AND proc_cmdline LIKE '%-n%' AND proc_cmdline NOT LIKE '%127.0.0.1%')
    
    -- 进程终止
    OR proc_name IN ('taskkill.exe', 'pskill.exe', 'kill.exe')
    
    -- 时间检测
    OR proc_cmdline LIKE '%Get-Date%'
    OR proc_cmdline LIKE '%[DateTime]::Now%'
  )
GROUP BY host_ip, host_name, proc_name, proc_fullpath, proc_cmdline, user_name
ORDER BY alert_count DESC
LIMIT 100;


-- ============================================================
-- PART 4: 综合统计报告
-- ============================================================

-- 4.1 各策略告警数量统计
SELECT 
    '策略1-可疑路径进程' AS alert_type,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_name IN (
    'cmd.exe', 'powershell.exe', 'powershell_ise.exe',
    'rundll32.exe', 'regsvr32.exe', 'mshta.exe',
    'wscript.exe', 'cscript.exe', 'certutil.exe',
    'bitsadmin.exe', 'msiexec.exe', 'svchost.exe',
    'lsass.exe', 'csrss.exe', 'winlogon.exe', 'wininit.exe',
    'services.exe', 'smss.exe', 'taskmgr.exe', 'mmc.exe'
  )
  AND proc_fullpath IS NOT NULL
  AND proc_fullpath NOT LIKE '%\\Windows\\System32\\%'
  AND proc_fullpath NOT LIKE '%\\Windows\\SysWOW64\\%'

UNION ALL

SELECT 
    '策略2-危险命令行' AS alert_type,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_cmdline IS NOT NULL
  AND (
    (proc_name = 'powershell.exe' AND proc_cmdline LIKE '%-EncodedCommand%')
    OR (proc_name = 'certutil.exe' AND proc_cmdline LIKE '%-urlcache%')
    OR (proc_name = 'mshta.exe' AND proc_cmdline LIKE '%http%')
    OR (proc_name = 'rundll32.exe' AND proc_cmdline LIKE '%javascript:%')
    OR (proc_name = 'regsvr32.exe' AND proc_cmdline LIKE '%http%')
  )

UNION ALL

SELECT 
    '策略3-异常父子进程' AS alert_type,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_parent_name IS NOT NULL
  AND (
    (proc_parent_name IN ('WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE', 'OUTLOOK.EXE', 'MSACCESS.EXE')
     AND proc_name IN ('cmd.exe', 'powershell.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe'))
    OR (proc_parent_name = 'svchost.exe' AND proc_name IN ('cmd.exe', 'powershell.exe'))
  )

UNION ALL

SELECT 
    '策略4-横向移动' AS alert_type,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND (
    proc_name IN ('psexec.exe', 'psexec64.exe', 'PAExec.exe', 'psexesvc.exe')
    OR (proc_name = 'wmic.exe' AND proc_cmdline IS NOT NULL AND proc_cmdline LIKE '%/node:%')
  )

UNION ALL

SELECT 
    '策略5-持久化' AS alert_type,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_cmdline IS NOT NULL
  AND (
    proc_cmdline LIKE '%reg add%\\Run%'
    OR (proc_name = 'schtasks.exe' AND proc_cmdline LIKE '%/create%')
    OR (proc_name = 'sc.exe' AND proc_cmdline LIKE '%create%')
  )

UNION ALL

SELECT 
    '策略6-权限提升' AS alert_type,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND (
    proc_name IN ('fodhelper.exe', 'eventvwr.exe', 'runas.exe', 'procdump.exe')
    OR (proc_cmdline IS NOT NULL AND proc_cmdline LIKE '%\\config\\SAM%')
  )

UNION ALL

SELECT 
    '策略7-数据窃取' AS alert_type,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_cmdline IS NOT NULL
  AND (
    proc_cmdline LIKE '%password%'
    OR proc_cmdline LIKE '%credential%'
    OR proc_name IN ('ftp.exe', 'winscp.exe', 'nc.exe')
  )

UNION ALL

SELECT 
    '策略8-反沙箱' AS alert_type,
    COUNT(*) AS alert_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
  AND proc_cmdline IS NOT NULL
  AND (
    proc_cmdline LIKE '%systeminfo%'
    OR proc_cmdline LIKE '%vmware%'
    OR proc_cmdline LIKE '%virtualbox%'
    OR proc_name IN ('taskkill.exe', 'pskill.exe')
  )


-- 4.2 高风险主机 TOP 20（按告警数量）
SELECT 
    host_ip,
    host_name,
    COUNT(DISTINCT proc_fullpath) AS unique_proc_count,
    COUNT(*) AS total_proc_count,
    SUM(CASE 
        WHEN proc_name IN ('cmd.exe', 'powershell.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe')
             AND proc_cmdline IS NOT NULL
             AND (proc_cmdline LIKE '%http://%' OR proc_cmdline LIKE '%https://%')
        THEN 1 ELSE 0 
    END) AS remote_exec_count,
    SUM(CASE 
        WHEN proc_cmdline IS NOT NULL AND (
            proc_cmdline LIKE '%-EncodedCommand%'
            OR proc_cmdline LIKE '%certutil%-urlcache%'
            OR proc_cmdline LIKE '%mimikatz%'
        )
        THEN 1 ELSE 0 
    END) AS high_risk_count
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
GROUP BY host_ip, host_name
ORDER BY high_risk_count DESC, remote_exec_count DESC
LIMIT 20;


-- ============================================================
-- PART 5: 临时清理（执行完分析后可删除）
-- ============================================================
-- DROP TABLE IF EXISTS temp_alert_results;
