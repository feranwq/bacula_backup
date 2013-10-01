#!/bin/bash
#
# Script for backups ....
#
# Usage:
# 
# bacula_backup.sh [-u] [-s]
#
# With parameter '-s', the script run a setup, which leads user through configuration of backup script and which creates
# a backup filesystem in the file on the remote system (bacula).
#
# With parameter '-u', the script unmounts the backup filesystem and the remote filesystem.
#
# Without parameters, the script tries to mount the remote file-system and the backup file-system and if succeed
# it:
# 1) check for uncompleted backup and possibly starts rsync to complete it.
# 2) If it is ${period_of_incremental_backup} from last finished backup it starts incremental backup using hardlinks to the previous one.
# 3) If it is ${period_of_full_backup} form the last full backup it starts full backup (probably using copy of the previous last backup)
#
# TODO:
# - reporting the backup process into a log file
# - review possible output for batch part of the script (non setup part)
# - setup CRON (with at command) during setup phase
# - measure timings of full and incremental
# - how to setup filter of dirs to copy, rsync filter is very flexible, but inconvenient
# - automatically exclude mount points for bacula and backup
# - how to treat files with wrong permissions (can not read ...)
# - write total size of stored data to ONE common logfile 
# - add '-m' parameter for mounting, always end with unmount 
#
# Speed tests (
# ------------------------
# speedup due to direct access to the sparse file):
# du ~/archiv
# 1629024 /home/jb/archiv/
#
# time bacula_backup.sh ~/archiv                # speed 12.5 MB/s  = 100Mb/s
# real    2m9.770s
# user    0m11.253s
# sys     0m12.497s
#
# time cp -r ~/archiv/ ~/mnt/bacula/            # speed 8.7 MB/s = 70Mb/s
# real    3m6.736s
# user    0m0.088s
# sys     0m8.553s
# ------------------------------
# full_backup (copy whole $HOME, by rsync):
# real    108m12.324s
# user    14m51.456s
# sys     17m36.450s
#
#
# empty_backup (copy only changed files - nearly none):
# real    6m38.486s
# user    0m25.382s
# sys     1m2.744s
# 
# To make sparse file:
# # create file with potential size 3.2 TB
# dd if=/dev/zero of=filename.img bs=1k seek=3200M count=1
# # set corret owner
# chown USER:USER filename.img
#


set -x 

# root of dir hierarchy to backup
backup_root="${HOME}" 

# rsync filter to use (see man rsync, section FILTER RULES)
# basic usage:
# + /backup_thing_in_root
# - /exclude_thing_in_root
# + backup_thing_with_path_ending_by_this
# - exclude_path_with_this_ending
# 
# For every file the filter is passed, first pattern that match is used, if it is 'include=+' the file is copied
# if it is 'exclude=-' the file is not copied and if no pattern match the file IS copied.
#
# pitfalls:
# /dir/*** - match directory in root and all its subdirs !!
# - /***   - exclude everything at the end
# !!! do not forget a whitespace at the end of the filter line !!!
# you can use usual unix file patterns
#

read -r -d '' filter_list <<'FILTER'
- /Osobni/filmy/***
- /Osobni/music/***
- /Osobni/fotky/***
- /.secure/***
- /mnt/***
+ /***
FILTER

credit_file="${HOME}/.secure/.bacula_backup_credit"

#

# directory where to mount bacula (should not contain spaces !!)
bacula_mount_dir=${HOME}/mnt/bacula

# directory where to mount backup filesystem
backup_mount_dir=${HOME}/mnt/backup

# loop device (should be unique on local system)
# usualy correct values are loop0 up to loop7
loop_device="/dev/loop0"

# address (UNC) of bacula (should not contain spaces !!)
# also username should not contain spaces
bacula_UNC="//bacula.nti.tul.cz"
backup_file="private/backup_sparse_image"
bacula_losetup="${HOME}/.secure/.bacula_losetup"
filter_file="${HOME}/.secure/.filter_file"

# script itself
backup_script="${0}"

# log file path - script dir + bacula_backup.log
backup_log_file="${0%/*}/backula_backup.log"

# How often the incremental backup is made - in hours.
period_of_incremental_backup="24"

# How often the full backup is made - in days.
period_of_full_backup="30"


# Empty if run in non-batch mode (i.e. from console).
# Otherwise number of failures of backup_mount from 
# the last regular call. On the failure, we plane the next call one hour later.
RUN_ID=

# creates creditial file for CIFS
# located at ${credit_file}
# global variables: credit_file
function make_creditial_file {
  local create_credit_file="no"
  local user_name=""
  local password=""
  
  if [ -f "${credit_file}" ]
  then
    echo "The credentials file '${credit_file}' exists, do you want to overwrite it? (yes/no) [default: no]"
    read create_credit_file
  else
    create_credit_file="yes"
  fi

  if [ "${create_credit_file}" = "yes" ] 
  then
    # create creditials file
    echo "Your user name for Samba server:"
    read user_name
    echo "Your passwod (will be stored in readable form in file only readable by owner):"
    read password

    rm -f "$credit_file"
    touch "$credit_file"
    chmod 600 "$credit_file"
    echo "username=$user_name" >>"$credit_file"
    echo "password=$password" >>"$credit_file"
    echo "domain=" >>"$credit_file"
    chmod 400 "$credit_file"
  fi
}


# add or modify entries in fstab about two mount points
# global variables: bacula_mount_dir, backup_mount_dir, 
#		    credit_file, loop_device, bacula_UNC
function modify_fstab {
  local user_name=`cat "${credit_file}" | grep "username=" | sed 's/username=//'`
  local uid=`whoami`

  # modify /etc/fstab - add bacula mount
  cat /etc/fstab | grep -v "${bacula_mount_dir}" >/tmp/fstab_work
  echo "# bacula mount dir: ${bacula_mount_dir}" >> /tmp/fstab_work
  echo "${bacula_UNC}/public/${user_name} ${bacula_mount_dir} cifs noauto,user,rw,credentials=${credit_file},_netdev,forceuid=${uid}   0 0 " >> /tmp/fstab_work
 
  # modify /etc/fstab - add backup mount
  cat /tmp/fstab_work | grep -v "${backup_mount_dir}" >/tmp/fstab_work2
  echo "# backup mount dir: ${backup_mount_dir}" >> /tmp/fstab_work2
  echo "${loop_device} ${backup_mount_dir} ext4 noauto,user,rw   0 0 " >> /tmp/fstab_work2
  
  echo "I have to add bacula mount point and backup mount point into /etc/fstab, please enter your password:"
  sudo mv -f '/etc/fstab' '/etc/~fstab_save'
  sudo cp '/tmp/fstab_work2' '/etc/fstab' 
  echo "/etc/fstab modified, original saved to /etc/~fstab_save"
  rm -f /tmp/fstab_work /tmp/fstab_work2
}


# creates program for creating and deleting particular loop device
# setuid can not be used for scripts bacause of race conditions
#
# global vars: bacula_mount_dir, backup_file, loop_device, bacula_losetup
function make_losetup_hook {
  local backup_file_full="${bacula_mount_dir}/${backup_file}"

  cat <<END  >/tmp/bacula_source.c
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc > 1 && argv[1][0] == 'd') 
    system("losetup -d ${loop_device}");
  else
    system("losetup ${loop_device} ${backup_file_full}");
 return 0;
}
END
  gcc /tmp/bacula_source.c -o /tmp/bacula_losetup
  sudo mkdir -p ${bacula_losetup%/*}
  sudo mv /tmp/bacula_losetup ${bacula_losetup}
  sudo chown root:root ${bacula_losetup}
  sudo chmod 4755 ${bacula_losetup} # set user ID and execute by every one  
}

function setup {
  make_creditial_file

  # make mount directories
  if [ ! -d ${bacula_mount_dir} ]; then mkdir -p ${bacula_mount_dir}; fi  
  if [ ! -d ${backup_mount_dir} ]; then mkdir -p ${backup_mount_dir}; fi  
  modify_fstab

  make_losetup_hook
 
  # try to mount samba destination and create loop device
  ${bacula_losetup} d              # remove possibly existing loop
  umount "${bacula_mount_dir}"
  if ! mount "${bacula_mount_dir}"
  then
    echo "Error: Can not mount bacula at setup."
    exit 2
  fi

  local backup_file_full="${bacula_mount_dir}/${backup_file}"
  if [ ! -f "${backup_file_full}" ]
  then
    echo "Can not find file for backup file system: ${backup_file_full}."
    ls -l "${bacula_mount_dir}/private"  
    #umount "${bacula_mount_dir}"
    exit 2
  fi

  # create loop device
  ${bacula_losetup}
  
  # try to mount loop device
  if ! mount "${backup_mount_dir}" 
  then
    echo "Can not mount backup file system. Trying to fix it ..."
    sudo e2fsck -p ${loop_device}
    if ! mount "${backup_mount_dir}" 
    then 
      echo "Either fatal coruption of the filesystem or filesystem not created yet. Would you create a new one 
            and overwrite the old one. YOU LOST ALL DATA. (yes/no) [default: no]"
      read create_new_fs
      if [ "${create_new_fs}" = "yes" ] 
      then
	sudo mkfs.ext4 "${loop_device}"
	if ! mount "${backup_mount_dir}" 
	then
	    echo "Fatal error: Can not mount created backup filesystem."
	    umount "${bacula_mount_dir}"
	    exit 2
	fi
      else
	echo ".. no way."
	umount "${bacula_mount_dir}"
	exit 2
      fi
    fi
  fi
  
  user=`whoami`
  sudo chown ${user}:${user} "${backup_mount_dir}"
  # try to list root dir of backup filesystem
  echo "Setup sucessfull, this is root dir of backup filesystem:"
  ls -a "${backup_mount_dir}"
  
  sudo umount "${backup_mount_dir}"  
  ${bacula_losetup} d 
  sudo umount "${bacula_mount_dir}"
}



# This function tries to:
# 1) mount bacula samba fs
# 2) create loop device
# 3) mount loop device,
# 4) run fsck on mount error
#
# If some step fail the function exits with err code 1
#
function backup_mount {
  # check creditials file
  if [ ! -e "${credit_file}" ] 
  then
    echo "Warning: Can not find creditials file. Bacula may not mount correctly."
  fi

  # make mount directories
  if [ ! -d ${bacula_mount_dir} ]; then mkdir -p ${bacula_mount_dir}; fi  
  if [ ! -d ${backup_mount_dir} ]; then mkdir -p ${backup_mount_dir}; fi  

  # check mount point in fstab
  if ! grep "${bacula_mount_dir}" /etc/fstab >/dev/null
  then
    echo "Error: Can not find bacula mount point /etc/fstab."
    return 1
  fi

  # check mount point in fstab
  if ! grep "${backup_mount_dir}" /etc/fstab >/dev/null
  then
    echo "Error: Can not find backup mount point in /etc/fstab."
    return 1
  fi

  # try to mount bacula
  if df|grep "${bacula_mount_dir}" || mount "${bacula_mount_dir}" 
    then :      # nop command
    else
      echo "Error: Can not mount bacula mount point /etc/fstab."
      return 1
    fi
  

  # check existing backup file
  backup_file_full="${bacula_mount_dir}/${user_name}/${backup_file}"
  if [ ! -f "${backup_file_full}" ]
  then
    ls -a "${mount_dir}"
    echo "Can not find file for backup file system: ${backup_file_full}."
    echo "Ask administrator of Bacula server to create a sparse file for this purpose."
    umount "${bacula_mount_dir}"
    exit 2
  fi

  # create loop device
  ${bacula_losetup}

  # try to mount backup file system
  if df|grep "${backup_mount_dir}" || mount "${backup_mount_dir}"
  then :
  else
    echo "Warning: Can not mount backup file system. Would you start filesystem check? yes/no [default: yes]"
    read answer
    if [ "$answer" == "no" ] 
    then
      echo "... no way."
      umount "${bacula_mount_dir}"
      exit 2
    else
      e2fsck -p ${loop_device}
      if ! mount "${backup_mount_dir}"
      then
	echo "Error: Can not fix the backup file system."
	umount "${bacula_mount_dir}"
	exit 2
      fi
    fi
  fi 

  #ls -l "${backup_mount_dir}/.."
  #user=`whoami`
  #sudo chown ${user}:${user} "${backup_mount_dir}"
}




# new comment
function make_backup {

  date_str=`date +%Y_%m_%d_%H%M%S`
  #backup_log_file=${HOME}/"backup_${date_str}.log"
  
  # write ${filter_list} into filter file
  echo "${filter_list}" > ${filter_file}

  # All following dirs should be without leading path
  
  # last completed full backup, that is not older than  ${period_of_full_backup} days
  last_actual_full_backup="`find ${backup_mount_dir} -maxdepth 1 -mtime -${period_of_full_backup}  -name "full_*" -type d \
  |sed 's|/$||' | sed 's|^.*/||' | head -n 1`"
  # last completed backup, that is not older than  ${period_of_incremental_backup} hours
  period_mins=$(( period_of_incremental_backup * 60 ))
  #period_mins=1
  last_actual_backup="`find ${backup_mount_dir} -mindepth 1 -maxdepth 1 -mmin -${period_mins} -type d | grep -v "running_*" \
  |sed 's|/$||' | sed 's|^.*/||' | head -n 1`"
  # any last completed backup
  last_backup="`ls -t -1 -d "${backup_mount_dir}"/*/ | grep -v "running_*" \
  |sed 's|/$||' | sed 's|^.*/||' | head -n 1`"
  # get full path of any running backup
  running_backup="`ls -d -1 "${backup_mount_dir}"/running_*/ \
  |sed 's|/$||' | sed 's|^.*/||' | head -n 1`"
  
  if [ "${running_backup}" != "" ]
  then
    # update the directory date, and set it as destination of new backup
    new_backup="${running_backup%%[0-9]*}${date_str}"   
    mv "${backup_mount_dir}/${running_backup}" "${backup_mount_dir}/${new_backup}"
  elif [ "${last_actual_full_backup}" == "" ]
  then
    new_backup="running_full_${date_str}"
    rm -f "${backup_mount_dir}/${new_backup}"
    mkdir "${backup_mount_dir}/${new_backup}"
  elif [ "${last_actual_backup}" == "" ]
  then 
    new_backup="running_${date_str}"
    rm -f "${backup_mount_dir}/${new_backup}"
    mkdir "${backup_mount_dir}/${new_backup}"
  else
    new_backup=""
  fi
  
  # logging header
  echo "==============================================================================================" >>${backup_log_file}
  echo "${new_backup}" >> ${backup_log_file}
  echo >> ${backup_log_file}
    

  #DRY="-v -n" 
  # -v          Verbose.
  # --progess   Progress for individual files.
  # -x          Do not cross filesystem boundaries. Prevents recursion.
  # --chmod ... alow user to read
  COMMON_OPT="--stats -x -a --delete"
  ulimit -u 1 
  if [ "${new_backup%%full_*}" != "${new_backup}" ]
  then
      # make full backup
      "time" ionice --class Idle nice -n 15 rsync ${COMMON_OPT} --filter=". ${filter_file}" "${backup_root}/" "${backup_mount_dir}/${new_backup}" &>>${backup_log_file}
      err=$?    # get error code
  elif [ ! -z "${new_backup}" ]
  then
      "time" ionice --class Idle nice -n 15 rsync ${COMMON_OPT} --filter=". ${filter_file}" --link-dest="${backup_mount_dir}/${last_backup}" "${backup_root}/" "${backup_mount_dir}/${new_backup}" &>>${backup_log_file}
      err=$?
  fi
  
  # rename to completed
  if [ -z "${new_backup}" ]     # no rsync performed
  then
    umount_all
  # elif [ -z "${err}"  -o  "${err}" == "0"  ]          # rsync without error ... remove running prefix
  elif [ -z "${err}" -o "${err}" == "0" ]          # rsync without error ... remove running prefix
  then 
    mv "${backup_mount_dir}/${new_backup}" "${backup_mount_dir}/${new_backup#running_}"
    umount_all
  else 
      if [ "${err}" == "23" ]  
      then
        # check if there are only 'permision denied' complains in the log
        if ! cat ${backup_log_file} | grep "rsync:" | grep -v "Permission denied (13)"
        then 
          echo "Warning: Some files was not backup, due to wrong permissions:"
          cat ${backup_log_file} | grep "rsync:"
          mv "${backup_mount_dir}/${new_backup}" "${backup_mount_dir}/${new_backup#running_}"
          umount_all
        else 
          echo "Error: Some files was not backup."
        fi
      else
        echo "Error: rsync ended with error code: ${err}"
      fi     
  fi    
}



#
#  Plans to run the script next day (for every day bacup)
#
function plan_next_day {
at 14:30 tomorrow <<END
  ${backup_script} -rid 0
END
}  



#
#  Plans to rerun the script next hour (if the backup fails)
#
function plan_next_hour {  
at now + 15 minutes <<END
  ${backup_script} -rid ${RUN_ID}
END
}  





function umount_all {
  if df|grep "${backup_mount_dir}"
  then 
    umount "${backup_mount_dir}"
  fi
  
  ${bacula_losetup} d
  
  if df|grep "${bacula_mount_dir}"
  then
    umount "${bacula_mount_dir}"
  fi    
}




#################################################
# parse parameters
while [ -n "$1" ]
do
  if [ "$1" == "-s" ]; then
    shift
    setup="yes"
  elif [ "$1" == "-u" ]; then
    umount_all
    exit
  elif [ "$1" == "-m" ]; then
    backup_mount
    exit
  elif [ "$1" == "-rid" ]; then
    shift
    RUN_ID="$1"
    shift
  else  
    backup_root=$1
    shift
  fi
done  


# look for configuration file
if [ -n "$setup"  ]
then
  setup
else
  # on regular batch call plan next regular backup call
  if [ "${RUN_ID}" == "0" ]
  then
    plan_next_day
  fi
  
  # try to mount the backup point
  if ! backup_mount
  then
    if [ -z "${RUN_ID}" ]
    then
      echo "Some error occured. Try to use '-s' option to setup backup."
      exit 2
    else
      if [ "${RUN_ID}" -lt "32" ]
      then
        RUN_ID=$(( RUN_ID + 1 ))    
        plan_next_hour
        exit 2
      else
        mail -s "bacula_backup can not mount the backup point" "jan.brezina@tul.cz" <<END        
END
        exit 2
      fi  
    fi
  fi
  
  make_backup
fi

