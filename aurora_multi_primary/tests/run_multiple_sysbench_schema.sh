#!/bin/bash
# example of usage
# for schema  in plain compressed ;do for test in sysbench sysbench_rw tpcc;do ./run_multiple_sysbench_schema.sh $schema ${test};done;done




schema=${1:-"plain"}
test=${2:-"sysbench"}
port=3306
MAINDIR=/opt/results
time=1200
LOGFILE=$MAINDIR/sysbench_results/sysbench_${test}_${schema}_$(date +'%Y-%m-%d_%H_%M').txt
mysqlhost=${3:-"192.168.4.2"}

th_loops="16 32 64 128 256 512"

echo "Running test:$test"

print_date_time(){
 echo "$(date +'%Y-%m-%d_%H_%M_%S')"
}

if [ "${schema}" == "compressed" ];
 then
  compressed="Y";
fi

nc -w 1 -z $mysqlhost $port
if [ $? -ne 0 ] ; then
    echo "[ERROR] Mysql did not start correctly" >> "${LOGFILE}"
  exit 1
else
  echo "[OK] Mysql running correctly" >> "${LOGFILE}"
fi




if [ $test == "sysbench" ] ;
 then
        schema="sbenchw"
        if [ "A${compressed}" == "AY" ];
        then
        schema="sbenchwc";
        fi
        echo "     Testing  $test $(print_date_time) ${schema} [START]" >> "${LOGFILE}"

        cd /opt/tools/sysbench

        if [ ! -d "$MAINDIR/sysbench_results" ]; then
            mkdir -p $MAINDIR/sysbench_results
        fi

        for threads in ${th_loops};do
                echo "RUNNING Test $test READ ONLY Thread=$threads [START] $(print_date_time) " >> "${LOGFILE}"
                echo "======================================" >>  "${LOGFILE}"
                sysbench /opt/tools/sysbench/src/lua/windmills/oltp_read.lua  --mysql-host=$mysqlhost --mysql-port=$port --mysql-user=<> --mysql-password=<>  --mysql-db=${schema} --db-driver=mysql --tables=200 --table_size=1000000  --time=$time  --rand-type=zipfian --rand-zipfian-exp=0 --skip_trx=on  --report-interval=1 --mysql-ignore-errors=all  --auto_inc=off --histogram --table_name=windmills  --stats_format=csv --db-ps-mode=disable --threads=$threads run >> "${LOGFILE}"
                echo "======================================" >> "${LOGFILE}"
                echo "RUNNING Test $test Thread=$threads [END] $(print_date_time) " >> "${LOGFILE}"
        done;
    cd /opt/tools
        echo "Testing  $test $(date +'%Y-%m-%d_%H_%M_%S') [END]" >> "${LOGFILE}";
fi


if [ $test == "sysbench_rw" ] ;
 then
        schema="sbenchw"
        if [ "A${compressed}" == "AY" ];
        then
        schema="sbenchwc";
        fi
        echo "     Testing  $test $(print_date_time) ${schema} [START]" >> "${LOGFILE}"

    cd /opt/tools/sysbench

        if [ ! -d "$MAINDIR/sysbench_results" ]; then
            mkdir -p $MAINDIR/sysbench_results
        fi

        for threads in ${th_loops};do
                echo "RUNNING Test $test OLTP Thread=$threads [START] $(print_date_time) " >> "${LOGFILE}"
                echo "======================================" >>  "${LOGFILE}"

                sysbench /opt/tools/sysbench/src/lua/windmills/oltp_read_write.lua  --mysql-host=$mysqlhost --mysql-port=$port --mysql-user=<> --mysql-password=<>  --mysql-db=${schema} --db-driver=mysql --tables=200 --table_size=1000000  --time=$time  --rand-type=zipfian --rand-zipfian-exp=0 --skip_trx=off  --report-interval=1 --mysql-ignore-errors=all  --auto_inc=off --histogram --table_name=windmills  --stats_format=csv --db-ps-mode=disable --threads=$threads run >> "${LOGFILE}"
                echo "======================================" >> "${LOGFILE}"
                echo "RUNNING Test $test Thread=$threads [END] $(print_date_time) " >> "${LOGFILE}"
        done;
    cd /opt/tools
        echo "Testing  $test $(date +'%Y-%m-%d_%H_%M_%S') [END]" >> "${LOGFILE}";
fi

if [ $test == "tpcc" ] ;
 then
        cd /opt/tools/sysbench-tpcc

        schema="tpcc"
        if [ "A${compressed}" == "AY" ];
        then
        schema="tpcc_c";
        fi
        echo "     Testing  $test $(print_date_time) ${schema} [START]" >> "${LOGFILE}"

        if [ ! -d "$MAINDIR/sysbench_results" ]; then
            mkdir -p $MAINDIR/sysbench_results
        fi

        for threads in ${th_loops};do
                echo "RUNNING Test $test Thread=$threads [START] $(print_date_time) " >>  "${LOGFILE}"
                echo "======================================" >>  "${LOGFILE}"
                sysbench /opt/tools/sysbench-tpcc/tpcc.lua --mysql-host=$mysqlhost --mysql-port=$port --mysql-user=<> --mysql-password=<>  --mysql-db=tpcc --db-driver=mysql --tables=10 --scale=15 --time=$time  --rand-type=zipfian --rand-zipfian-exp=0 --report-interval=1 --mysql-ignore-errors=all --histogram  --report_csv=yes --stats_format=csv --db-ps-mode=disable --threads=$threads run  >>  "${LOGFILE}"
                echo "======================================" >>  "${LOGFILE}"
                echo "RUNNING Test $test Thread=$threads [END] $(print_date_time) " >>  "${LOGFILE}"
        done;
        echo "Testing  $test $(date +'%Y-%m-%d_%H_%M_%S') [END]" >>  "${LOGFILE}" ;
    cd /opt/tools
fi