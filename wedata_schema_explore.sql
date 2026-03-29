-- ============================================================
-- WeData 表结构探索（先执行这个文件确认字段）
-- 表名：yd_onion_interface.sec_yd_t_win_new_proc_info
-- ============================================================

-- 1. 查看一条样本数据（用于确认所有字段名）
SELECT *
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
LIMIT 1;

-- 2. 查看字段数量和字段名
-- 注意：TDW/Hive 不支持 DESC，用 SELECT 来推断
-- 执行上面 SQL 后，记录返回的字段名列表

-- 3. 确认关键字段是否存在
SELECT 
    proc_fullpath,
    proc_name,
    proc_cmdline,
    proc_parent_name,
    host_ip,
    host_name,
    user_name
FROM yd_onion_interface.sec_yd_t_win_new_proc_info
WHERE tdbank_imp_date = '20260319'
LIMIT 10;

-- 4. 如果上面 SQL 报错，说明字段名可能不同
-- 请尝试以下常见字段名变体：
-- proc_path / process_path / image_path
-- cmdline / command_line / process_command_line
-- parent_name / parent_process_name / pproc_name
-- ip / src_ip / source_ip
-- hostname / src_host
-- user / username / account_name
