#!/bin/bash -ue

skip=true
NUMC=${NUMC:-3}
SDURATION=${SDURATION:-300}
TSIZE=${TSIZE:-1000}
NUMT=${NUMT:-16}
STEST=${STEST:-oltp}
AUTOINC=${AUTOINC:-off}
TCOUNT=${TCOUNT:-10}
SHUTDN=${SHUTDN:-yes}
TXRATE=${TXRATE:-120}
RSLEEP=${RSLEEP:-10}
RMOVE=${RMOVE:-1}
LOSS="${LOSS:-1%}"
DELAY="${DELAY:-3ms}"
CMD=${CMD:-"/pxc/bin/mysqld --defaults-extra-file=/pxc/my.cnf --basedir=/pxc --user=mysql --skip-grant-tables --innodb-buffer-pool-size=500M --innodb-log-file-size=100M --query_cache_type=0  --wsrep_slave_threads=16 --innodb_autoinc_lock_mode=2  --query_cache_size=0 --innodb_flush_log_at_trx_commit=0 --innodb_file_per_table "}
LPATH=${SPATH:-/usr/share/doc/sysbench/tests/db}
thres=1 
RANDOM=$$
BUILD_NUMBER=${BUILD_NUMBER:-$RANDOM}
SLEEPCNT=${SLEEPCNT:-10}
FSYNC=${FSYNC:-0}

TMPD=${TMPDIR:-/tmp}
ALLINT=${ALLINT:-1}
COREDIR=${COREDIR:-/var/crash}
ECMD=${EXTRA_CMD:-" --wsrep-sst-method=rsync --core-file "}
RSEGMENT=${RSEGMENT:-1}
LOSSNO=${LOSSNO:-1}
PROVIDER=${EPROVIDER:-0}

HOSTSF="$PWD/hosts"
EXCL=${EXCL:-1}
VSYNC=${VSYNC:-1}
CATAL=${COREONFATAL:-0}

if [[ ${BDEBUG:-0} -eq 1 ]];then 
    set -x
fi

SOCKS=""
SOCKPATH="/tmp/pxc-socks"

SDIR="$LPATH"
export PATH="/usr/sbin:$PATH"

linter="eth0"
FORCE_FTWRL=${FORCE_FTWRL:-0}

FIRSTD=$(cut -d" " -f1 <<< $DELAY | tr -d 'ms')
RESTD=$(cut -d" " -f2- <<< $DELAY)

echo "
[sst]
sst-initial-timeout=$(( 50*NUMC ))
" > /tmp/my.cnf

if [[ $NUMC -lt 3 ]];then 
    echo "Specify at least 3 for nodes"
    exit 1
fi

# Hack for jenkins only. uh.. 
if [[ -n ${BUILD_NUMBER:-} && $(groups) != *docker* ]]; then
    exec sg docker "$0 $*"
fi

if [[ $PROVIDER == '1' ]];then 
    CMD+=" --wsrep-provider=/pxc/libgalera_smm.so"
    PGALERA=" -v $PWD/libgalera_smm.so:/pxc/libgalera_smm.so -v /tmp/my.cnf:/pxc/my.cnf"
    #cp -v $PWD/libgalera_smm.so /pxc/
else 
    PGALERA="-v /tmp/my.cnf:/pxc/my.cnf"
fi


pushd ../docker-tarball
count=$(ls -1ct Percona-XtraDB-Cluster-*.tar.gz | wc -l)

if [[ $count -eq 0 ]];then 
    echo "FATAL: Need tar.gz"
    exit 2
fi


if [[ $count -gt $thres ]];then 
    for fl in `ls -1ct Percona-XtraDB-Cluster-*.tar.gz | tail -n +2`;do 
        rm -f $fl || true
    done 
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-*' -exec rm -rf {} \+ || true 


TAR=`ls -1ct Percona-XtraDB-Cluster-*.tar.gz | head -n1`
BASE="$(tar tf $TAR | head -1 | tr -d '/')"

tar -xf $TAR

rm -rf Percona-XtraDB-Cluster || true

mv $BASE Percona-XtraDB-Cluster

NBASE=$PWD/Percona-XtraDB-Cluster

MD5=$(md5sum < $TAR | cut -d" " -f1)
if [[ ! -e $TMPD/MD5FILE ]];then 
    skip=false
    echo -n $MD5 > $TMPD/MD5FILE
else 
    EMD5=$(cat $TMPD/MD5FILE)

    if [[ $MD5 != $EMD5 ]];then 
        echo -n $MD5 > $TMPD/MD5FILE
        skip=false
    else 
        skip=true
    fi
fi 
popd

#if git log --summary -1 -p  | grep -q '/Dockerfile';then 
    #skip=false
#fi

if [[ $FORCEBLD == 1 ]];then 
    skip=false
fi

LOGDIR="$TMPD/logs/$BUILD_NUMBER"
mkdir -p $LOGDIR

runum(){
    local cmd="$1"
    for x in `seq 1 50`; do 
        eval $cmd Dock$x
    done 
}
runc(){
    local cont=$1
    shift
    local cmd1=$1
    shift 
    local cmd2=$1
    local ecmd 
    if [[ $cmd1 == 'mysql' ]];then 
        ecmd=-e
    else 
        ecmd=""
    fi
    local hostt=$(docker port $cont 3306)
    local hostr=$(cut -d: -f1 <<< $hostt)
    local portr=$(cut -d: -f2 <<< $hostt)
    $cmd1 -h $hostr -P $portr -u root $ecmd  "$cmd2"

}


cleanup(){
    local cnt
    set +e 



    for s in `seq 1 $NUMC`;do 
        docker logs -t Dock$s &>$LOGDIR/Dock$s.log
    done


    docker logs -t dnscluster > $LOGDIR/dnscluster.log
    if [[ $SHUTDN == 'yes' ]];then 
        docker stop dnscluster  &>/dev/null
        docker rm -f  dnscluster &>/dev/null
        echo "Stopping docker containers"
        runum "docker stop" &>/dev/null
        echo "Removing containers"
        runum "docker rm -f " &>/dev/null
    fi
    pkill -9 -f socat
    rm -rf $SOCKPATH && mkdir -p $SOCKPATH
    #rm -rf $LOGDIR

    now=$(date +%s)
    for s in `seq 1 $NUMC`;do 
        sudo journalctl --since=$(( then-now )) | grep  "Dock${s}-" > $LOGDIR/journald-Dock${s}.log
    done
    sudo journalctl -b  > $LOGDIR/journald-all.log
    tar cvzf $TMPD/results-${BUILD_NUMBER}.tar.gz $LOGDIR  
    set -e 

    echo "Checking for core files"

    if [[ "$(ls -A $COREDIR)" ]];then
        echo "Core files found"
        for cor in $COREDIR/*.core;do 
            cnt=$(cut -d. -f1 <<< $cor)
            sudo gdb $NBASE/bin/mysqld --quiet --batch --core=$cor -ex "set logging file $LOGDIR/$cnt.trace" --command=../backtrace.gdb
        done 
    fi

    pgid=$(ps -o pgid= $$ | grep -o '[0-9]*')
    kill -TERM -$pgid || true

}
mshutdown(){ 

    faildown=""

    echo "Shutting down servers"
    for s in `seq 1 $NUMC`;do 
        echo "Shutting down container Dock${s}"
        runc Dock$s  mysqladmin shutdown || failed+=" Dock${s}"
    done

    if [[ -n $faildown ]];then
        echo "Failed in shutdown: $failed"
        SHUTDN='no'
    fi

}

preclean(){
    set +e
    echo "Stopping old docker containers"
    runum "docker stop" &>/dev/null 
    echo "Removing  old containers"
    runum "docker rm -f" &>/dev/null 
    docker stop dnscluster &>/dev/null 
    docker rm -f dnscluster &>/dev/null
    pkill -9 -f socat
    pkill -9 -f mysqld
    rm -rf $SOCKPATH && mkdir -p $SOCKPATH
    set -e 
}

wait_for_up(){
    local cnt=$1
    local count=0
    local hostt=$(docker port $cnt 3306)
    local hostr=$(cut -d: -f1 <<< $hostt)
    local portr=$(cut -d: -f2 <<< $hostt)

    set +e 
    while ! mysqladmin -h $hostr -P $portr -u root ping &>/dev/null;do 
        echo "Waiting for $cnt"
        sleep 5
        if [[ $count -gt $SLEEPCNT ]];then 
            echo "Failure"
            exit 1
        else 
            count=$(( count+1 ))
        fi
    done 
    echo "$cnt container up and running!"
    SLEEPCNT=$(( SLEEPCNT+count ))
    set -e
}

spawn_sock(){
    local cnt=$1
    hostt=$(docker port $cnt 3306)
    hostr=$(cut -d: -f1 <<< $hostt)
    portr=$(cut -d: -f2 <<< $hostt)
    local socket=$SOCKPATH/${cnt}.sock
    socat UNIX-LISTEN:${socket},fork,reuseaddr TCP:$hostr:$portr &
    echo "$cnt also listening on $socket for $hostr:$portr" 
    if [[ -z $SOCKS ]];then 
        SOCKS="$socket"
    else
        SOCKS+=",$socket"
    fi
}

belongs(){
    local elem=$1
    shift
    local -a arr=$@
    for x in ${arr[@]};do 
        if [[ $elem == $x ]];then 
            return 0
        fi
    done 
    return 1
}


trap cleanup EXIT KILL

preclean

if [[ $skip == "false" ]];then
    pushd ../docker-tarball
    docker build  --rm -t ronin/pxc:tarball -f Dockerfile.centos7-64 . 2>&1 | tee $LOGDIR/Dock-pxc.log 
    popd
    # Required for core-dump analysis
    # rm -rf Percona-XtraDB-Cluster || true
fi

CSTR="gcomm://Dock1"

#for nd in `seq 2 $NUMC`;do 
    #CSTR="${CSTR},Dock${nd}"
#done 

rm -f $HOSTSF && touch $HOSTSF

# Some Selinux foo
chcon  -Rt svirt_sandbox_file_t  $HOSTSF &>/dev/null  || true
chcon  -Rt svirt_sandbox_file_t  $COREDIR &>/dev/null  || true

docker run  -d  -i -v $HOSTSF:/dnsmasq.hosts --name dnscluster ronin/dnsmasq &>$LOGDIR/dnscluster-run.log

dnsi=$(docker inspect  dnscluster | grep IPAddress | grep -oE '[0-9\.]+')

echo "Starting first node"

declare -a segloss
if [[ $RSEGMENT == 1 ]];then 
    SEGMENT=$(( RANDOM % (NUMC/2) ))
    segloss[0]=$(( SEGMENT/2+1 ))
else 
    SEGMENT=0
fi

if [[ $FSYNC == '0' || $VSYNC == '1' ]];then 
    PRELOAD="/usr/lib64/libeatmydata.so"
else 
    PRELOAD=""
fi

docker run -P -e LD_PRELOAD=$PRELOAD -e FORCE_FTWRL=$FORCE_FTWRL   -d -t -i -h Dock1 -v $COREDIR:/pxc/crash $PGALERA   --dns $dnsi --name Dock1 ronin/pxc:tarball bash -c "ulimit -c unlimited && chmod 777 /pxc/crash && $CMD $ECMD --wsrep-new-cluster --wsrep-provider-options='gmcast.segment=$SEGMENT; evs.auto_evict=3; evs.version=1;  evs.info_log_mask=0x3'" &>$LOGDIR/run-Dock1.log

wait_for_up Dock1
spawn_sock Dock1
FIRSTSOCK="$SOCKPATH/Dock1.sock"

firsti=$(docker inspect  Dock1 | grep IPAddress | grep -oE '[0-9\.]+')
echo "$firsti Dock1" >> $HOSTSF
echo "$firsti Dock1.ci.percona.com" >> $HOSTSF
echo "$firsti meant for Dock1"

set -x
sysbench --test=$LPATH/parallel_prepare.lua ---report-interval=10  --oltp-auto-inc=$AUTOINC --mysql-db=test  --db-driver=mysql --num-threads=$NUMT --mysql-engine-trx=yes --mysql-table-engine=innodb --mysql-socket=$FIRSTSOCK --mysql-user=root  --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT    prepare 2>&1 | tee $LOGDIR/sysbench_prepare.txt 
set +x

mysql -S $FIRSTSOCK -u root -e "create database testdb;" || true


nexti=$firsti
sleep 5


RANDOM=$(date +%s)
for rest in `seq 2 $NUMC`; do
    echo "Starting node#$rest"
    lasto=$(cut -d. -f4 <<< $nexti)
    nexti=$(cut -d. -f1-3 <<< $nexti).$(( lasto+1 ))
    echo "$nexti Dock${rest}" >> $HOSTSF
    echo "$nexti Dock${rest}.ci.percona.com" >> $HOSTSF
    echo "$nexti meant for Dock${rest}"
    if [[ $RSEGMENT == "1" ]];then 
        SEGMENT=$(( RANDOM % (NUMC/2) ))
        segloss[$(( rest-1 ))]=$(( SEGMENT/2+1 ))
    else 
        SEGMENT=0
    fi

    if [[  $FSYNC == '0' || ( $VSYNC == '1'  && $(( RANDOM%2 )) == 0 ) ]];then 
        PRELOAD="/usr/lib64/libeatmydata.so"
    else 
        PRELOAD=""
    fi
    set -x
    docker run -P -e LD_PRELOAD=$PRELOAD -e FORCE_FTWRL=$FORCE_FTWRL -d -t -i -h Dock$rest -v $COREDIR:/pxc/crash $PGALERA --dns $dnsi --name Dock$rest ronin/pxc:tarball bash -c "ulimit -c unlimited && chmod 777 /pxc/crash && $CMD $ECMD --wsrep_cluster_address=$CSTR --wsrep_node_name=Dock$rest --wsrep-provider-options='gmcast.segment=$SEGMENT; evs.auto_evict=3; evs.version=1; evs.info_log_mask=0x3'" &>$LOGDIR/run-Dock${rest}.log
    set +x
    #CSTR="${CSTR},Dock${rest}"

    if [[ $(docker inspect  Dock$rest | grep IPAddress | grep -oE '[0-9\.]+') != $nexti ]];then 
        echo "Assertion failed  $nexti,  $(docker inspect  Dock$rest | grep IPAddress | grep -oE '[0-9\.]+') "
        exit 1
    fi
    sleep $(( rest*2 ))
done


echo "Waiting for all servers"
for s in `seq 2 $NUMC`;do 
    wait_for_up Dock$s
    spawn_sock Dock$s
done


# Will be needed for LOSS-WITH-SST
#int1=$(brctl show docker0  | tail -n +2 | grep -oE 'veth[a-z0-9]+' | head -1)
#sudo tc qdisc add dev $int1 root netem delay $DELAY loss $LOSS

#sysbench --test=$LPATH/parallel_prepare.lua ---report-interval=10  --oltp-auto-inc=$AUTOINC --mysql-db=test  --db-driver=mysql --num-threads=$NUMT --mysql-engine-trx=yes --mysql-table-engine=innodb --mysql-socket=$SOCKS --mysql-user=root  --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT    prepare 2>&1 | tee $LOGDIR/sysbench_prepare.txt 
#sysbench --test=$LPATH/oltp.lua ---report-interval=10  --oltp-auto-inc=$AUTOINC --mysql-db=test  --db-driver=mysql --num-threads=$NUMT --mysql-engine-trx=yes --mysql-table-engine=innodb --mysql-socket=$SOCKS --mysql-user=root  --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT    prepare 2>&1 | tee $LOGDIR/sysbench_prepare.txt 

#echo "Interfaces"
#ip addr
sleep 10

totsleep=10
echo "Pre-Sanity tests"
runagain=0
while true; do
    runagain=0
    for s in `seq 1 $NUMC`;do 
        stat1=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_cluster_status'" 2>/dev/null | tail -1)
        stat2=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_state_comment'" 2>/dev/null | tail -1)
        stat3=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_recv_queue'" 2>/dev/null | tail -1)
        stat4=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_send_queue'" 2>/dev/null | tail -1)
        stat5=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_evs_delayed'" 2>/dev/null | tail -1)
        if [[ $stat1 != 'Primary' || $stat2 != 'Synced' || $stat3 != '0' || $stat4 != '0' ]];then 
            echo "Waiting for Dock${s} (or some other node to empty) to become really synced or primary: $stat1, $stat2, $stat3, $stat4, $stat5"
            runagain=1
            break
        else 
            echo "Dock${s} is synced and is primary: $stat1, $stat2, $stat3, $stat4, $stat5"
        fi
    done
    if [[ $runagain -eq 1 ]];then 
        sleep 10
        totsleep=$(( totsleep+10 ))
        continue
    else 
        break
    fi
done 

echo "Slept for $totsleep in total"


for s in `seq 1 $NUMC`;do 
    for x in `seq 1 $TCOUNT`;do
        if ! mysql -S $SOCKPATH/Dock${s}.sock -u root -e "select count(*) from test.sbtest$x" &>>$LOGDIR/sanity-pre.log;then 
            echo "FATAL: Failed in pre-sanity state for Dock${s} and table $x"
            exit 1
        fi
    done 
done

declare -a ints
declare -a intf
declare -a intall 

if [[ $ALLINT == 1 ]];then 
    echo "Adding loss to $LOSSNO nodes out of $NUMC"
    intf=(`shuf -i 1-$NUMC -n $LOSSNO`)
fi

intall=(`seq 1 $NUMC`)



if [[ $ALLINT == 1 ]];then 
    for int in ${intall[@]};do 
        echo "Adding delay to Dock${int} out of ${intall[@]}"

        dpid=$(docker inspect -f '{{.State.Pid}}' Dock${int})

        sudo nsenter  -t $dpid -n tc qdisc replace dev $linter root handle 1: prio


        if [[ $RSEGMENT == "1" ]];then 
            DELAY="$(( FIRSTD*${segloss[$(( int-1 ))]} ))ms $RESTD"
        else 
            DELAY="${FIRSTD}ms $RESTD"
        fi

        if belongs $int ${intf[@]};then 
            sudo nsenter  -t $dpid -n tc qdisc add dev $linter parent 1:2 handle 30: netem delay $DELAY loss $LOSS
        else 
            sudo nsenter  -t $dpid -n tc qdisc add dev $linter parent 1:2 handle 30: netem delay $DELAY 
        fi
    done
else 
    echo "Adding delay $DELAY  and loss $LOSS"


    dpid=$(docker inspect -f '{{.State.Pid}}' Dock1)

    sudo nsenter  -t $dpid -n tc qdisc replace dev $linter root handle 1: prio


    if [[ $RSEGMENT == "1" ]];then 
        DELAY="$(( FIRSTD*${segloss[0]} ))ms $RESTD"
    else 
        DELAY="${FIRSTD}ms $RESTD"
    fi

    sudo nsenter  -t $dpid -n tc qdisc add dev $linter parent 1:2 handle 30: netem delay $DELAY loss $LOSS

fi


if [[ $ALLINT == 1 && $EXCL == 1 ]];then 
    SOCKS=""
    for nd in `seq 1 $NUMC`;do 
        if belongs $nd ${intf[@]};then 
            echo "Skipping Dock${nd} from SOCKS for loss"
            continue
        else 
            if [[ -z $SOCKS ]];then 
                SOCKS="$SOCKPATH/Dock${nd}.sock"
            else 
                SOCKS+=",$SOCKPATH/Dock${nd}.sock"
            fi
        fi
    done 
    echo "sysbench on sockets: $SOCKS"
fi


echo "Rules in place"

for s in `seq 1 $NUMC`;do 
    dpid=$(docker inspect -f '{{.State.Pid}}' Dock${s})
    sudo nsenter -t $dpid -n tc qdisc show
done

if [[ ! -e $SDIR/${STEST}.lua ]];then 
    pushd /tmp

    rm $STEST.lua || true
    wget -O $STEST.lua  http://files.wnohang.net/files/${STEST}.lua
    SDIR=/tmp/
    popd
fi

set -x
if [[ $ALLINT == 1 ]];then 
    timeout -k9 $(( SDURATION+200 )) sysbench --test=$SDIR/$STEST.lua --mysql-ignore-errors=1047,1213  --db-driver=mysql --mysql-db=test --mysql-engine-trx=yes --mysql-table-engine=innodb --mysql-socket=$SOCKS --mysql-user=root  --num-threads=$TCOUNT --init-rng=on --max-requests=1870000000    --max-time=$SDURATION  --oltp_index_updates=20 --oltp_non_index_updates=20 --oltp-auto-inc=$AUTOINC --oltp_distinct_ranges=15 --report-interval=10  --oltp_tables_count=$TCOUNT run 2>&1 | tee $LOGDIR/sysbench_rw_run.txt
else 
    timeout -k9 $(( SDURATION+200 )) sysbench --test=$SDIR/$STEST.lua --mysql-ignore-errors=1047,1213  --db-driver=mysql --mysql-db=test --mysql-engine-trx=yes --mysql-table-engine=innodb --mysql-socket=$FIRSTSOCK --mysql-user=root  --num-threads=$TCOUNT --init-rng=on --max-requests=1870000000    --max-time=$SDURATION  --oltp_index_updates=20 --oltp_non_index_updates=20 --oltp-auto-inc=$AUTOINC --oltp_distinct_ranges=15 --report-interval=10  --oltp_tables_count=$TCOUNT run 2>&1 | tee $LOGDIR/sysbench_rw_run.txt
fi
set +x

if [[ $RMOVE == '1' ]];then 
    if [[ $ALLINT == 1 ]];then 
        for int in ${intall[@]};do 

            echo "Removing delay $DELAY  and loss $LOSS for container Dock${int}"
            dpid=$(docker inspect -f '{{.State.Pid}}' Dock${int})
            #sudo nsenter -t $dpid -n tc qdisc del dev $linter root netem || true
            sudo nsenter  -t $dpid -n tc qdisc change dev $linter parent 1:2 handle 30: netem delay $DELAY || true
        done
    else 
        echo "Removing delay $DELAY  and loss $LOSS for Dock1"
        dpid=$(docker inspect -f '{{.State.Pid}}' Dock1)
        #sudo nsenter -t $dpid -n tc qdisc del dev $linter root netem || true
        sudo nsenter  -t $dpid -n tc qdisc change dev $linter parent 1:2 handle 30: netem delay $DELAY || true
    fi
fi

for s in `seq 1 $NUMC`;do 

    #if [[ $RMOVE == '0' ]] && belongs $s ${intf[@]};then 
        #echo "Skipping Dock${s} from SOCKS"
        #continue
    #fi 
    stat1=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_cluster_status'" 2>/dev/null | tail -1)
    stat2=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_state_comment'" 2>/dev/null | tail -1)
    stat3=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_recv_queue'" 2>/dev/null | tail -1)
    stat4=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_send_queue'" 2>/dev/null | tail -1)
    stat5=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_evs_delayed'" 2>/dev/null | tail -1)
    if [[ $stat1 != 'Primary' || $stat2 != 'Synced'  ]];then 
        echo "Dock${s} seems to be not stable: $stat1, $stat2, $stat3, $stat4, $stat5"
    else 
        echo "Dock${s} is synced and is primary: $stat1, $stat2, $stat3, $stat4, $stat5"
    fi
done

echo "Sleeping for $RSLEEP seconds for reconciliation"
sleep $RSLEEP 

echo "Sanity tests"
echo "Statuses"
maxsleep=300
totsleep=0

while true;do 
    exitfatal=0
    whichisstr=""
    for s in `seq 1 $NUMC`;do 

        if [[ $RMOVE == '0' ]] && belongs $s ${intf[@]};then 
            echo "Skipping Dock${s} from SOCKS"
            continue
        fi 
        stat1=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_cluster_status'" 2>/dev/null | tail -1)
        stat2=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_state_comment'" 2>/dev/null | tail -1)
        stat3=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_recv_queue'" 2>/dev/null | tail -1)
        stat4=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_send_queue'" 2>/dev/null | tail -1)
        stat5=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_evs_delayed'" 2>/dev/null | tail -1)
        if [[ $stat1 != 'Primary' || $stat2 != 'Synced'  ]];then 
            echo "FATAL: Dock${s} seems to be STILL unstable: $stat1, $stat2, $stat3, $stat4, $stat5"
            stat=$(mysql -nNE -S $SOCKPATH/Dock${s}.sock -u root -e "show global status like 'wsrep_local_state'" 2>/dev/null | tail -1)
            echo "wsrep_local_state of Dock${s} is $stat"
            if  [[ $stat1 == 'Primary' && ( $stat == '2' || $stat == '1' || $stat == '3' || $stat2 == *Join* || $stat2 == *Don* ) ]];then 
                exitfatal=3
                whichisstr="Dock${s}"
                break
            else
                exitfatal=1
            fi
        else 
            echo "Dock${s} is synced and is primary: $stat1, $stat2, $stat3, $stat4, $stat5"
        fi
    done
    if [[ $exitfatal -eq 1 || $totsleep -gt $maxsleep ]];then 
        exitfatal=1
        break
    elif [[ $exitfatal -eq 3 ]];then
        echo " $whichisstr is still donor/joiner, sleeping 60 seconds"
        sleep 60
        totsleep=$(( totsleep+60 ))
    else 
        break
    fi
    echo 
    echo
done 


echo "Sanity queries"

for s in `seq 1 $NUMC`;do 

    if [[ $RMOVE == '0' ]] && belongs $s ${intf[@]};then 
        echo "Skipping Dock${s} from SOCKS"
        continue
    fi 
    for x in `seq 1 $TCOUNT`;do
        echo "For table test.sbtest$x from node Dock${s}" | tee -a $LOGDIR/sanity.log
        mysql -S $SOCKPATH/Dock${s}.sock -u root -e "select count(*) from test.sbtest$x" 2>>$LOGDIR/sanity.log || exitfatal=1
    done 
done

if [[ $exitfatal -eq 1 ]];then 
    echo "Exit fatal"
    if [[ $CATAL == '1' ]];then 
        echo "Killing with SIGSEGV for core dumps"
        pkill -11 -f mysqld || true 
        sleep 60
    fi
    exit 1
fi

echo "Sleeping 5s before drop table"
sleep 5

set -x
 timeout -k9 $(( SDURATION+200 )) sysbench --test=$LPATH/parallel_prepare.lua ---report-interval=10  --oltp-auto-inc=$AUTOINC --mysql-db=test  --db-driver=mysql --num-threads=$NUMT --mysql-engine-trx=yes --mysql-table-engine=innodb --mysql-socket=$SOCKS --mysql-user=root  --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT    cleanup 2>&1 | tee $LOGDIR/sysbench_cleanup.txt 
set +x

sleep 20

mysql -S $FIRSTSOCK  -u root -e "drop database testdb;" || SHUTDN='no'

sleep 10 

if [[ $SHUTDN == 'no' ]];then 
    echo "Exit before cleanup"
    exit
fi

mshutdown
