```
[client]
port = 3307
socket = /opt/mysql_instances/test-tpcc-xxx/mysql.sock
ssl-ca = /opt/mysql_templates/xxx/cert/ca.pem
ssl-cert = /opt/mysql_templates/xxx/cert/client-cert.pem
ssl-key = /opt/mysql_templates/xxx/cert/client-key.pem
ssl-mode = disabled
[mysqldump]
quick
quote-names
max_allowed_packet  = 48M
[mysql]
prompt=(\\u@\\h) [\\d]>\\
[isamchk]
key_buffer    = 16M
[mysqld_safe]
log-error = /opt/mysql_instances/test-tpcc-xxx/mysql-3307.err
open-files-limit= 65536
[mysqld]
basedir                                                     =/opt/mysql_templates/xxx/
datadir = /opt/mysql_instances/test-tpcc-xxx/data
lc_messages_dir                                             =/opt/mysql_templates/xxx/share/
local_infile                                                = 1
log-error = /opt/mysql_instances/test-tpcc-xxx/mysql-3307.err
pid-file = /opt/mysql_instances/test-tpcc-xxx/mysqld.pid
plugin-dir                                                  =/opt/mysql_templates/xxx/lib/plugin/
port = 3307
secure-file-priv                                            =""
server-id = 3307
socket = /opt/mysql_instances/test-tpcc-xxx/mysql.sock
tmpdir = /opt/mysql_instances/test-tpcc-xxx/temp
user                                                        =mysql
default_time_zone='+01:00'
max-connections                                             =2500
table_definition_cache                                     = 4096
tablespace-definition-cache                                 =256
table_open_cache                                           = 4096
table-open-cache-instances                                  =4
thread_cache_size                                          = 1024
thread_stack                                               = 256K
thread_handling                                            = one-thread-per-connection
binlog_cache_size	= 1M
binlog_stmt_cache_size = 1M
join_buffer_size = 32M
max_heap_table_size = 16M
read_buffer_size = 1M
read_rnd_buffer_size = 16M
sort_buffer_size = 1M
tmp_table_size = 16M
innodb_adaptive_hash_index                                  =off
innodb_autoinc_lock_mode                                    =2
innodb_buffer_pool_in_core_file                             =OFF
innodb_buffer_pool_instances                                =4
innodb_buffer_pool_size                                     =10G
innodb_change_buffering                                     =none
innodb_data_file_path                                       =ibdata1:100M:autoextend
innodb_data_home_dir                                        = /opt/mysql_instances/test-tpcc-xxx/data
innodb_doublewrite_pages                                    =128
innodb_use_fdatasync                                        =1
innodb_io_capacity                                          =10000
innodb_log_buffer_size                                      =64M
innodb_redo_log_capacity                                    =2G
innodb_log_group_home_dir                                   = /opt/mysql_instances/test-tpcc-xxx/logs
innodb_monitor_enable					                    =all
innodb_numa_interleave                                      =ON
innodb_read_io_threads                                      = 20
innodb_redo_log_capacity                                    = 3355443200
innodb_sync_array_size                                      = 12
innodb_write_io_threads                                     = 32
log_bin = /opt/mysql_instances/test-tpcc-xxx/logs/binlog
binlog_expire_logs_seconds=10
long_query_time=240
slow-query-log = 0
slow-query-log-file = /opt/mysql_instances/test-tpcc-xxx/logs/slow.log
general-log-file = /opt/mysql_instances/test-tpcc-xxx/logs/general.log
general-log                                                 =0
```