#!/bin/bash
#########################################################################################
# ps-toolkit-migrate-restore.sh <backup-tarball>
# 
# This script reads in a tarball file generated by "ps-toolkit-migrate-backup" and places
# the files it contain at their required location. This includes creating UNIX user 
# accounts and rebuilding database data.
#
# WARNING: This script may overwrite data on the target system. It is expected this script
# will be run on a freshly installed machine with no non-root users or existing data. 
# Also, in its current form, running it multiple times may result in the same user and 
# groups being created multiple times. Use in the above cases at your own risk as you may
# lose  data or get unexpected results.
#########################################################################################

TEMP_BAK_NAME=ps-toolkit-migrate-backup
TEMP_RST_NAME=ps-toolkit-migrate-restore
TEMP_RST_DIR="/tmp/$TEMP_RST_NAME"

#Check parameters
TEMP=$(getopt -o d --long data -n $0 -- "$@")
if [ $? != 0 ]; then
    echo "Usage: $0 [-d|--data] <tgz-file>"
    echo "Unable to parse command line"
    exit 1
fi
eval set -- "$TEMP"

while true; do
   case "$1" in
       -d|--data) DATA=1 ; shift ;;
       --) shift ; break ;;
       *) echo "Internal error!" ; exit 1 ;;
   esac
done

#Check options
if [ -z "$1" ]; then
    echo "Usage: $0 [-d|--data] <tgz-file>"
    echo "Missing path to tar file in options list"
    exit 1
fi

#Create temp directory
rm -rf $TEMP_RST_DIR
mkdir -m 700 $TEMP_RST_DIR
if [ "$?" != "0" ]; then
    echo "Unable to create temp directory"
    exit 1
fi

#Unpack back up files
if [ -f "$1" ]; then
    tar -xzf $1 -C $TEMP_RST_DIR
else
    echo "File $1 does not exist"
    exit 1
fi

#get users
EXISTING_USERS=`awk -v LIMIT=500 -F: '($3>=LIMIT) && ($3!=65534)' /etc/passwd`
if [ -n "$EXISTING_USERS" ]; then
    echo "WARN: Looks like non-root user accounts were created prior to running this script. Skipping user account restoration to avoid conflicts"
else
    printf "Restoring users..."
    if [ -f "$TEMP_RST_DIR/$TEMP_BAK_NAME/etc/passwd" ]; then
        cat $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/passwd >> /etc/passwd 
        if [ "$?" != "0" ]; then
            echo "Unable to restore /etc/passwd"
            exit 1
        fi
        awk -F: '{ print $6 }' $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/passwd | xargs --no-run-if-empty mkdir
    fi
    printf "[SUCCESS]"
    echo ""

    #get groups
    printf "Restoring groups..."
    if [ -f "$TEMP_RST_DIR/$TEMP_BAK_NAME/etc/group" ]; then
        cat $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/group >> /etc/group
        if [ "$?" != "0" ]; then
            echo "Unable to restore /etc/group"
            exit 1
        else
            #finish setting permission on home directories now that groups are created
            awk -F: '{ system("chown "$1":"$1" "$6) }' $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/passwd
        fi
    fi
    printf "[SUCCESS]"
    echo ""

    #get shadow file
    printf "Restoring passwords..."
    if [ -f "$TEMP_RST_DIR/$TEMP_BAK_NAME/etc/shadow" ]; then
        cat $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/shadow >> /etc/shadow 
        if [ "$?" != "0" ]; then
            echo "Unable to restore /etc/shadow"
            exit 1
        fi
    fi
    printf "[SUCCESS]"
    echo ""
fi

#get administrative info
printf "Restoring toolkit configuration..."
cp -a $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/perfsonar/* /etc/perfsonar
if [ "$?" != "0" ]; then
    echo "Unable to restore /etc/perfsonar"
    exit 1
fi
printf "[SUCCESS]"
echo ""

#get bwctl files
printf "Restoring bwctl-server configuration..."
cp -a $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/bwctl-server/*  /etc/bwctl-server
if [ "$?" != "0" ]; then
    echo "Unable to restore /etc/bwctl-server"
    exit 1
fi
printf "[SUCCESS]"
echo ""

#get owamp files
printf "Restoring owamp-server configuration..."
cp -a $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/owamp-server/* /etc/owamp-server
if [ "$?" != "0" ]; then
    echo "Unable to restore /etc/owamp-server"
    exit 1
fi
printf "[SUCCESS]"
echo ""

#get pscheduler if exists
if [ -d "$TEMP_RST_DIR/$TEMP_BAK_NAME/etc/pscheduler" ]; then
    printf "Restoring pScheduler configuration..."
    cp -a $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/pscheduler/* /etc/pscheduler
    if [ "$?" != "0" ]; then
        echo "Unable to restore /etc/pscheduler"
        exit 1
    fi
    printf "[SUCCESS]"
    echo ""
fi

#get NTP config
printf "Restoring NTP configuration..."
cp $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/ntp.conf /etc/ntp.conf 
if [ "$?" != "0" ]; then
    echo "Unable to restore /etc/ntp.conf"
    exit 1
fi
printf "[SUCCESS]"
echo ""

#get maddash if exists
if [ -f "$TEMP_RST_DIR/$TEMP_BAK_NAME/etc/maddash/maddash-server/maddash.yaml" ]; then
    printf "Restoring MaDDash configuration..."
    cp -a $TEMP_RST_DIR/$TEMP_BAK_NAME/etc/maddash/* /etc/maddash
    if [ "$?" != "0" ]; then
        echo "Unable to restore /etc/maddash"
        exit 1
    fi
    printf "[SUCCESS]"
    echo ""
fi

#restore databases
if [ "$DATA" ]; then
    if [ -d /var/lib/cassandra/data/esmond ]; then
        printf "Restoring cassandra data for esmond..."
        if ! /sbin/service cassandra stop &>/dev/null; then
            echo "Unable to stop cassandra"
            exit 1
        fi

        rm -f /var/lib/cassandra/commitlog/*.log /var/lib/cassandra/data/esmond/*/*.db
        for table in $(ls $TEMP_RST_DIR/$TEMP_BAK_NAME/cassandra_data); do
            cp -a $TEMP_RST_DIR/$TEMP_BAK_NAME/cassandra_data/$table/esmond_snapshot/* \
                  /var/lib/cassandra/data/esmond/$table/
            if [ "$?" != "0" ]; then
                echo "Unable to restore /var/lib/cassandra/data/esmond/$table"
                exit 1
            fi
        done

        if ! /sbin/service cassandra start &>/dev/null; then
            echo "Unable to start cassandra"
            exit 1
        fi
        for i in {1..10}; do
            nodetool status &>/dev/null && break
            sleep 1
        done
        if ! nodetool repair &>/dev/null; then
            echo "Unable to repair cassandra"
            exit 1
        fi
        printf "[SUCCESS]"
        echo ""
    fi

    printf "Restoring postgresql data for esmond..."
    export PGUSER=$(sed -n -e 's/sql_db_user = //p' /etc/esmond/esmond.conf)
    export PGPASSWORD=$(sed -n -e 's/sql_db_password = //p' /etc/esmond/esmond.conf)
    export PGDATABASE=$(sed -n -e 's/sql_db_name = //p' /etc/esmond/esmond.conf)
    psql --no-password < $TEMP_RST_DIR/$TEMP_BAK_NAME/postgresql_data/esmond.dump &>/dev/null
    if [ "$?" != "0" ]; then
        echo "Unable to restore esmond database"
        exit 1
    fi
    unset PGUSER PGPASSWORD PGDATABASE
    printf "[SUCCESS]"
    echo ""

    printf "Restoring postgresql data for pscheduler..."
    export PGUSER=$(sed -n -e 's/.*user=\([^ ]*\).*/\1/p' /etc/pscheduler/database/database-dsn)
    export PGPASSWORD=$(sed -n -e 's/.*password=\([^ ]*\).*/\1/p' /etc/pscheduler/database/database-dsn)
    export PGDATABASE=$(sed -n -e 's/.*dbname=\([^ ]*\).*/\1/p' /etc/pscheduler/database/database-dsn)
    psql --no-password < $TEMP_RST_DIR/$TEMP_BAK_NAME/postgresql_data/pscheduler.dump &>/dev/null
    if [ "$?" != "0" ]; then
        echo "Unable to restore pscheduler database"
        exit 1
    fi
    unset PGUSER PGPASSWORD PGDATABASE
    printf "[SUCCESS]"
    echo ""
fi

#Clean up temp directory
rm -rf $TEMP_RST_DIR
echo "Restore complete."
