[root@h-sldb-msp-4 sigterm_analyzer]# cat sigterm_analyzer.bash 
#!/bin/bash
# Author: Steve Chapman (stevcha@cdw.com)
# Purpose: Provide insight into SIGTERM log messages
#
# New in version:
#  2.2 - Fixed problem where backspace or non-numeric response (other than "q")
#        caused the script to spit a bunch of errors before returning the prompt
#  2.1 - Integration of 2.0 and 1.4
#  2.0 - Showstopper Logging Checks
#  1.4 - "count-only" and "monitor-output" options added
#      - if no matching SIGTERMs found, exit
#      - "quit" option when selecting collectors or processes
#  1.3 - Expanded device and app reports to include what failed with what
#      - Dev report shows collection frequency, with * if override in place
#  1.2 - Support for reviewing a collector group
#      - introduced log_it function to reduce code size
#  1.1 - MySQL errors suppressed
#      - Invalid process ID check added
#      - List collectors in columns to fit screen
#      - List device results in columns on screen
#      - Clean up text when no results found
#      - Code clean-up
#      - Support for using Collector Name instead of ID
#
VER="2.2"
re='^[0-9]+$'
EXCLUDE_COUNT=0
declare -a APP_CAT DEV_CAT

help_msg () {
        echo ; echo "Usage: $0 [-c {collector ID}] [-g {Collector Group ID}] [-o {output file}] [-p {process ID}] [-t {date}] [-d] [-i] [-s] [-a] [-f] [-s] [--count-only] [--monitor-output] [-h] [-v]"
        echo "  Where:"
        echo "    -a = Availability SIGTERMs"
        echo "    -c = Collector appliance ID"
        echo "    -d = Dynamic App SIGTERMs"
        echo "    -f = Filesystem Statistics SIGTERMs"
        echo "    -g = Collector Group (CUG) ID"
        echo "    -i = Interface Bandwidth SIGTERMs"
        echo "    -o = output results to filename provided"
        echo "    -p = the process ID for which you wish to collect SIGTERM info"
        echo "    -s = SNMP Detail SIGTERMs"
        echo "    -t = Specific date to pull in format YYYY-MM-DD"
        echo "    --count-only = print number of SIGTERMs and no more (count is by time, since a SIGTERM can result in multiple entries if multiple child processes were affected)"
        echo "    --monitor-output = just print the number of SIGTERMs for my monitoring software"
        echo "    -h = Help message (what you're reading now)"
        echo "    -v = version information" ; echo
}

last_step () {
        rm -f $OUTFILE
}

sql_cmd () {
        /opt/em7/bin/silo_mysql -NBe "$1" 2>/dev/null
}

log_it () {
        [[ $LOGFILE ]] && echo "$1" >> $LOGFILE
        echo "$1"
}

detect_showstopper_activity () {
# Went with minutes instead of seconds because sometimes the SIGTERM caused by showstopper doesn't get logged until after SiLo is restarted for a few seconds
#        SS_STOP_TIMES+=( $(sql_cmd "SELECT DATE_FORMAT(date, \"%Y%m%d%H%i%S\") FROM device_logs.logs_${COL_DID} WHERE message = 'showstopper: Stopping SiLo' $DATEQ") )
#        SS_START_TIMES+=( $(sql_cmd "SELECT DATE_FORMAT(date, \"%Y%m%d%H%i%S\") FROM device_logs.logs_${COL_DID} WHERE message = 'showstopper: Starting SiLo' $DATEQ") )
        SS_STOP_TIMES+=( $(sql_cmd "SELECT DATE_FORMAT(date, \"%Y%m%d%H%i\") FROM device_logs.logs_${COL_DID} WHERE message = 'showstopper: Stopping SiLo' $DATEQ") )
        SS_START_TIMES+=( $(sql_cmd "SELECT DATE_FORMAT(date, \"%Y%m%d%H%i\") FROM device_logs.logs_${COL_DID} WHERE message = 'showstopper: Starting SiLo' $DATEQ") )
        [[ ! ${SS_STOP_TIMES[@]} ]] && return
        if (( ${SS_START_TIMES[0]} < ${SS_STOP_TIMES[0]} )) ; then
                INITIAL_START_TIME="$(date -d "$(sql_cmd "SELECT DATE(date) FROM device_logs.logs_${COL_DID} WHERE message = 'showstopper: Starting SiLo' $DATEQ LIMIT 1") -1 days" +%Y-%m-%d)"
                INITIAL_STOP_TIME=$(sql_cmd "SELECT DATE_FORMAT(date, \"%Y%m%d%H%i%S\") FROM device_logs.logs_${COL_DID} WHERE message = 'showstopper: Stopping SiLo' AND DATE(date) = \"$INITIAL_START_TIME\" ORDER BY date DESC LIMIT 1")
                SS_STOP_TIMES=("$INITIAL_STOP_TIME" "${SS_STOP_TIMES[@]}")
        fi
        [[ ${#SS_STOP_TIMES[@]} -gt 0 ]] && SHOWSTOP=1 
}

start_report () {
        if [ ! $MON_OUT ] ; then
                echo ; log_it "Report for $PROCESS SIGTERMs on Collector $COL_NAME [$MODULE]" ; log_it ""
                [[ ! $SHOWSTOP ]] && log_it "Found $NUM_FOUND $PROCESS SIGTERMs:" || log_it "Found $NUM_FOUND $PROCESS SIGTERMs (excludes $EXCLUDE_COUNT attributed to showstopper):"
                log_it ""
                [[ $COUNT_ONLY ]] && last_step && exit 0
        else
                echo -n "${COL_NAME},${NUM_FOUND}"
                last_step && exit 0
        fi
}

caused_by_showstopper () {
# Went with minutes instead of seconds because sometimes the SIGTERM caused by showstopper doesn't get logged until after SiLo is restarted for a few seconds
#        OUTAGE_DATE=$(date +%Y%m%d%H%M%S -d "$LINE_DATE")
        OUTAGE_DATE=$(date +%Y%m%d%H%M -d "$LINE_DATE")
        [[ ! $OUTAGE_DATE ]] && echo "No date provided" && exit 1
        x=0
        while [ $x -lt ${#SS_STOP_TIMES[@]} ] ; do
                STOP_TIME=${SS_STOP_TIMES[$x]}
                START_TIME=${SS_START_TIMES[$x]}
                if (( $OUTAGE_DATE >= $STOP_TIME && $OUTAGE_DATE <= $START_TIME )) ; then
                        #remove lines with $LINE_DATE from $OUTFILE
                        sed -i "/{START-TAG/{:a;N;/END-TAG}/!ba};/$LINE_DATE/d" $OUTFILE
                        ((NUM_FOUND--))
                        ((EXCLUDE_COUNT++))
                fi
                ((x++))
        done
}

get_logs () {
        sql_cmd "SELECT date_edit,message FROM master_logs.system_messages WHERE module=$MODULE AND message LIKE \"%${PROCESS}%list at term%\" $QUERY ORDER BY date_edit" > $OUTFILE 
        NUM_FOUND=$(cat ${OUTFILE} | awk {'print $1,$2'} | uniq | wc -l) 
        readarray DTS < $OUTFILE
        i=0 ; while [ $i -lt ${#DTS[@]} ] ; do DTS[$i]="$(echo "${DTS[$i]}" | cut -f1)" ; ((i++)) ; done
        for STRING in "${DTS[@]}" ; do 
                [[ ! ${DTS_SORT[0]} ]] && DTS_SORT+=( "$STRING" )
                i=0 
                while [ $i -lt ${#DTS_SORT[@]} ] ; do [[ "$STRING" == "${DTS_SORT[$i]}" ]] && DONT_ADD=1 ; ((i++)) ; done 
                [[ ! $DONT_ADD ]] && DTS_SORT+=( "$STRING" )
                unset DONT_ADD
        done
        [[ $NUM_FOUND -gt 0 ]] && detect_showstopper_activity
        [[ $SHOWSTOP ]] && ind=0 &&  while [ $ind -lt ${#DTS_SORT[@]} ] ; do LINE_DATE="${DTS_SORT[$ind]}" ; caused_by_showstopper ; ((ind++)) ; done
        if [ $NUM_FOUND -eq 0 ] ; then
                if [ $MON_OUT ] ; then
                        echo -n "${COL_NAME},0" 
                        last_step && exit 0
                else
                        echo -n "No $PROCESS SIGTERMs found on $COL_NAME [${MODULE}]" 
                        [[ $SHOWSTOP ]] && echo " (excludes $EXCLUDE_COUNT attributed to showstopper)" || echo ""
                        last_step && exit 0
                fi
        fi
}

process_log_file () {
        while IFS= read -r LINE ; do
                LINE_DATE="$(echo $LINE | awk -F" ${PROC_NUM}: D" {'print $1'})"
                if [ $PROC_NUM -eq 11 ] ; then
                        ENTRY_DATE="$(date -d "$LINE_DATE" +"%Y%m%d-%H%M%S")"
                        DEVAPP_PAIRS="$(echo $LINE | awk -F"[" {'print $2'} | awk -F"]" {'print $1'})"
                        echo "$DEVAPP_PAIRS" >> devapp-pairs_${ENTRY_DATE}.log
                        sed -i 's/, 0)//g' devapp-pairs_${ENTRY_DATE}.log
                        sed -i 's/((/(/g' devapp-pairs_${ENTRY_DATE}.log
                        sed -i 's/), /)\n/g' devapp-pairs_${ENTRY_DATE}.log
                        echo "$LINE_DATE" > entry_${ENTRY_DATE}.log
                else
                        DEV_FAILS=( $(echo $LINE | awk -F"[" {'print $2'} | awk -F"]" {'print $1'}) )
                        if [ ${#DEV_FAILS[@]} -gt 0 ] ; then
                                log_it "  * Number of devices not collected at ${LINE_DATE}: ${#DEV_FAILS[@]}"
                                log_it "    * Devices: "
                                for DEVID in $(echo ${DEV_FAILS[@]} | sed 's/,//g') ; do
                                        HNAME="$(sql_cmd "SELECT device FROM master_dev.legend_device WHERE id=$DEVID")"
                                        log_it "        $HNAME [$DEVID]"
                                done | column -x -c $(tput cols)
                                unset DEV_FAILS DEVID LINE_DATE
                        else
                                log_it "  * Though the process SIGTERM'd at ${LINE_DATE}, no devices were listed."
                        fi ; log_it ""
                fi
        done < $OUTFILE
}

create_app_catalog () {
        APPID_CAT=( $(cat APPS_*.log | sort | uniq) )
        for AID in ${APPID_CAT[@]} ; do APP_CAT[$AID]="$(sql_cmd "SELECT CONCAT(name,' [',aid,']|',poll) FROM master.dynamic_app WHERE aid=$AID")" ; done
}

create_dev_catalog () {
        DEVID_CAT=( $(cat DEVS_*.log | sort | uniq) )
        for DEVID in ${DEVID_CAT[@]} ; do DEV_CAT[$DEVID]="$(sql_cmd "SELECT CONCAT(device,' [',id,']') FROM master_dev.legend_device WHERE id=$DEVID")" ; done
}

dynamic_app_device_report () {
        MISSED_APPS+=( $(grep $DEV devapp-pairs_${LINE_DATE}.log | awk -F", " {'print $2'} | awk -F")" {'print $1'}) )
        echo "    * Device ${DEV_CAT[$DEV]} failed to collect on dynamic apps:"
        for MA in ${MISSED_APPS[@]} ; do
                APP_NAME="$(echo "${APP_CAT[$MA]}" | awk -F"|" {'print $1'})"
                APP_FREQ="$(sql_cmd "SELECT freq FROM master.dynamic_app_freq_overrides WHERE app_id=$MA AND did=$DEV")*"
                [[ "$APP_FREQ" == "*" ]] && APP_FREQ=$(echo "${APP_CAT[$MA]}" | awk -F"|" {'print $2'})
                MA_INFO+=( "$APP_NAME (CF $APP_FREQ)" )
        done
        for PRINT_ME in "${MA_INFO[@]}" ; do log_it "        $PRINT_ME" ; done | column -x -c $(tput cols)
        unset MISSED_APPS MA_INFO PRINT_ME
        log_it
}

dynamic_app_app_report () {
        MISSED_DEVS+=( $(grep ", $APP" devapp-pairs_${LINE_DATE}.log | awk -F"," {'print $1'} | awk -F"(" {'print $2'}) )
        echo "    * Dynamic app $(echo ${APP_CAT[$APP]} | awk -F"|" {'print $1'}) failed to collect for devices:"
        for PRINT_ME in ${MISSED_DEVS[@]} ; do log_it "        ${DEV_CAT[$PRINT_ME]}" ; done | column -x -c $(tput cols)
        unset MISSED_DEVS PRINT_ME
        log_it
}

process_devapp_pairs () {
        for FILE in $(ls devapp-pairs*.log) ; do
                LINE_DATE=$(echo $FILE | awk -F"_" {'print $2'} | awk -F"." {'print $1'})
                while IFS= read -r LINE ; do
                        echo $LINE | awk -F", " {'print $1'} | awk -F"(" {'print $2'} >> DEVS_${LINE_DATE}.log
                        echo $LINE | awk -F", " {'print $2'} | awk -F")" {'print $1'} >> APPS_${LINE_DATE}.log
                done < $FILE
        done
        create_app_catalog
        create_dev_catalog
        for FILE in $(ls DEVS_*.log) ; do
                LINE_DATE=$(echo $FILE | awk -F"_" {'print $2'} | awk -F"." {'print $1'})
                ENTRY_DATE="$(cat entry_${LINE_DATE}.log)"
                TOTAL_DEVS=$(sed '/^\s*$/d' DEVS_${LINE_DATE}.log | wc -l)
                if [ $TOTAL_DEVS -gt 0 ] ; then
                        log_it "At $ENTRY_DATE, $TOTAL_DEVS device/app pairs:"
                        for DEV in $(cat DEVS_${LINE_DATE}.log | sort -n | uniq) ; do
                                NUM_DEVS=$(grep $DEV DEVS_${LINE_DATE}.log | wc -l)
                                log_it "  * Device ${DEV_CAT[$DEV]} appears $NUM_DEVS times"
                                dynamic_app_device_report
                        done
                        for APP in $(cat APPS_${LINE_DATE}.log | sort -n | uniq) ; do
                                NUM_APPS=$(grep $APP APPS_${LINE_DATE}.log | wc -l)
                                APP_NAME="$(echo ${APP_CAT[$APP]} | awk -F"|" {'print $1'})"
                                APP_FREQ="$(echo ${APP_CAT[$APP]} | awk -F"|" {'print $2'})"
                                log_it "  * Dynamic App ${APP_NAME} (frequency: $APP_FREQ min) appears $NUM_APPS times"
                                dynamic_app_app_report
                        done
                else
                        log_it "At $ENTRY_DATE, $PROCESS SIGTERM'd with no device/app pairs"
                fi
                log_it ""
                rm -f DEVS_${LINE_DATE}.log APPS_${LINE_DATE}.log devapp-pairs_${LINE_DATE}.log entry_${LINE_DATE}.log
        done
}

evaluate_cug () {
        ! [[ $CUG_ID =~ $re ]] && CUG_ID="$(sql_cmd "SELECT cug_id FROM master.system_collector_groups WHERE cug_name=\"$CUG_ID\"")"
        CUG_NAME="$(sql_cmd "SELECT cug_name FROM master.system_collector_groups WHERE cug_id=$CUG_ID")"
        [[ ! "$CUG_NAME" ]] && echo "Invalid Collector Group ID provided" && echo && exit 1
        [[ $(sql_cmd "SELECT COUNT(*) FROM master.system_collector_groups_to_collectors WHERE cug_id=$CUG_ID") -eq 0 ]] && echo "$CUG_NAME is a Virtual Collector Group; it has no collectors" && echo && exit 1
        CUG_QUERY="AND module IN (SELECT pid FROM master.system_collector_groups_to_collectors WHERE cug_id=$CUG_ID)"
}

while getopts "ac:dfg:hio:p:st:v-:" opt ; do
        case $opt in
                "a") PROCESS="Availability" ; PROC_NUM=10 ;;
                "c") MODULE=$OPTARG ;;
                "d") PROCESS="Dynamic App" ; PROC_NUM=11 ;;
                "f") PROCESS="Filesystem statistics" ; PROC_NUM=32 ;;
                "g") CUG_ID="$OPTARG" ;;
                "i") PROCESS="Interface Bandwidth" ; PROC_NUM=12 ;;
                "o") LOGFILE="$OPTARG" ; [[ $LOGFILE ]] && rm -f $LOGFILE ;;
                "p") PROC_NUM=$OPTARG ; PROCESS="$(echo $(sql_cmd "SELECT name FROM master.system_settings_procs WHERE aid=$PROC_NUM") | awk -F": " {'print $2'})" ;;
                "s") PROCESS="SNMP Detail" ; PROC_NUM=24 ;;
                "t") QUERY="AND DATE(date_edit) = \"$OPTARG\"" ; DATEQ="AND DATE(date) = \"$OPTARG\"" ;;
                "h") help_msg ; exit 0 ;;
                "v") echo ; echo "$0, version $VER" ; echo ; exit 0 ;;
                "-") case $OPTARG in
                        "collector") MODULE=$OPTARG ;;
                        "collector-group" | "CUG" | "cug") CUG_ID="$OPTARG" ;;
                        "date" | "time" ) QUERY="AND DATE(date_edit) = \"$OPTARG\"" ; DATEQ="AND DATE(date) = \"$OPTARG\"" ;;
                        "count-only") COUNT_ONLY=1 ;;
                        "monitor-output") MON_OUT=1 ;;
                        "outfile") LOGFILE="$OPTARG" ; [[ $LOGFILE ]] && rm -f $LOGFILE ;;
                        "process") PROC_NUM=$OPTARG ; PROCESS="$(echo $(sql_cmd "SELECT name FROM master.system_settings_procs WHERE aid=$PROC_NUM") | awk -F": " {'print $2'})" ;;
                        "help") help_msg ; exit 0 ;;
                        "version") echo ; echo "$0, version $VER" ; echo ; exit 0 ;;
                        "*") echo "Invalid option" ; echo ; help_msg ; exit 1 ;;
                     esac ;;
                *) help_msg ; exit 1 ;;
        esac
done

if [ ! $MODULE ] ; then
        [[ $CUG_ID ]] && evaluate_cug
        MOD_OPTIONS=( "$(sql_cmd "SELECT DISTINCT module FROM master_logs.system_messages WHERE message LIKE \"%${PROC_NUM}:%list at term%\" $QUERY $CUG_QUERY")" )
        CHECKVAL="x${MOD_OPTIONS[0]}x"
        [[ "$CHECKVAL" == "xx" ]] && echo "No collectors in ${CUG_NAME} had $PROCESS SIGTERMs" && exit 0
        for ID in ${MOD_OPTIONS[@]} ; do COLLECTORS+=( "$(sql_cmd "SELECT CONCAT(name,' [',id,']') FROM master.system_settings_licenses WHERE id=$ID")" ) ; done ; echo  
        [[ $CUG_NAME ]] && echo "Please select a collector ID from ${CUG_NAME}. Collectors from this CUG with SIGTERMs are: " || echo "Collector ID (-c) required. Options are: "
        echo ; echo "${COLLECTORS[@]/%/$'\n'}" | sed 's/^ //' | column -c $(tput cols) -x
        echo ; while [ ! $MODULE ] ; do
                printf "Which collector ID do you wish to analyze? [\"q\" to quit] "
                read MODULE
                [[ "$MODULE" == "q" ]] && last_step && exit 0
                [[ $MODULE =~ $re ]] && for is_match in ${MOD_OPTIONS[@]} ; do [[ $is_match -eq $MODULE ]] && move_on=1 ; done
                [[ ! $move_on ]] && unset MODULE 
        done
        unset move_on
else
        ! [[ $MODULE =~ $re ]] && MODULE=$(sql_cmd "SELECT id FROM master.system_settings_licenses WHERE name=\"$MODULE\"")
        [[ ! $MODULE ]] && echo "Collector not found" && exit 1
fi

if [ ! $PROC_NUM ] ; then
        PROC_OPTIONS=( "$(echo "$(sql_cmd "SELECT message FROM master_logs.system_messages WHERE module=$MODULE $QUERY AND message LIKE '%list at term%'")" | awk -F":" {'print $1'} | sort | uniq)" )
        [[ ! $PROC_OPTIONS ]] && echo "No SIGTERMs found" && echo && exit 0
        echo ; echo "No process given. Options are: " ; echo
        for PROC in ${PROC_OPTIONS[@]} ; do echo "  $(echo "$(sql_cmd "SELECT name FROM master.system_settings_procs WHERE aid=$PROC")" | awk -F": " {'print $2'}) [Process ID $PROC]" ; done
        echo ; while [ ! $PROC_NUM ] ; do
                printf "Which process ID would you like to analyze? [\"q\" to quit] "
                read PROC_NUM
                [[ "$PROC_NUM" == "q" ]] && last_step && exit 0
                [[ $PROC_NUM =~ $re ]] && for is_match in ${PROC_OPTIONS[@]} ; do [[ $is_match -eq $PROC_NUM ]] && move_on=1 ; done
                [[ ! $move_on ]] && unset PROC_NUM
        done
        PROCESS="$(sql_cmd "SELECT name FROM master.system_settings_procs WHERE aid=$PROC_NUM" | awk -F": " {'print $2'})"
else
        [[ "$(sql_cmd "SELECT COUNT(*) FROM master.system_settings_procs WHERE aid=$PROC_NUM")" != "1" ]] && echo "Invalid Process ID" && exit 1
fi

OUTFILE="${PROCESS// /_}"
OUTFILE="${MODULE}_${OUTFILE}.log"
COL_NAME="$(sql_cmd "SELECT name FROM master.system_settings_licenses WHERE id=$MODULE")"
COL_DID=$(sql_cmd "SELECT id FROM master_dev.legend_device WHERE device=\"$COL_NAME\" AND ip != ''")

[[ $PROC_NUM -eq 11 ]] && QUERY="$QUERY AND message NOT LIKE \"%'%\""
get_logs
if [ $NUM_FOUND -gt 0 ] ; then
        start_report 
        process_log_file
        [[ $PROC_NUM -eq 11 ]] && process_devapp_pairs
fi
echo ; last_step
