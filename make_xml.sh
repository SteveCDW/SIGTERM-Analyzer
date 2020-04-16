#!/bin/bash
VER="1.0"
DATE="$(date +%Y-%m-%d)"

help_msg () {
        echo ; echo "Usage: $0 [-c {collector name}] [-p {process ID}] [-d YYYY-MM-DD]"
        echo "where:"
        echo "  -c = collector name, optional (default all)"
        echo "  -p = process ID, optional (default all)"
        echo "  -d = date to collect in form of YYYY-MM-DD, optional (default today)"
        echo "  -h = help message (what you're reading now)"
        echo "  -v = show version number and exit"
        echo
}

while getopts "c:d:p:hv" opt ; do
        case $opt in
                "c") COLLECTORS+=( $OPTARG ) ;;
                "d") DATE="$OPTARG" ;;
                "p") PROCESSES+=( $OPTARG ) ;;
                "h") help_msg ; exit 0 ;;
                "v") echo "$0, version $VER" ; echo ; exit 0 ;;
        esac
done

[[ "$(/sbin/drbdsetup status | grep "r0 role" | awk -F":" {'print $2'})" != "Primary" ]] && exit 0
[[ ! $COLLECTORS ]] && COLLECTORS=( $(/opt/em7/bin/silo_mysql -NBe "SELECT name FROM master.system_settings_licenses WHERE function=5 ORDER BY name") )
[[ ! $PROCESSES ]] && PROCESSES=( 10 11 12 14 15 16 17 18 19 20 24 25 30 31 32 47 48 158 160 )
[[ ! -d "/usr/local/silo/gui/ap/www/xml" ]] && mkdir /usr/local/silo/gui/ap/www/xml

for COL_NAME in ${COLLECTORS[@]} ; do
        OUTFILE="/usr/local/silo/gui/ap/www/xml/${COL_NAME}_xml.out"
        echo "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>" > $OUTFILE
        echo "<sigterm_monitor>" >> $OUTFILE
        for PROC_ID in ${PROCESSES[@]} ; do
                RESULT="$(/home/em7admin/sigterm_analyzer/sigterm_analyzer.bash -c $COL_NAME -t $DATE -p $PROC_ID --monitor-output)"
                PROC_NAME="$(echo $RESULT | awk -F"," {'print $2'})"
                PROC_NAME="${PROC_NAME// /_}"
                NUM_SIGTERMS=$(echo $RESULT | awk -F"," {'print $3'})
                echo "    <${PROC_NAME}>${NUM_SIGTERMS}</${PROC_NAME}>" >> $OUTFILE
        done
        echo "</sigterm_monitor>" >> $OUTFILE
done
