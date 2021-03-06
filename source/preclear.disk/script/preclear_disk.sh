#!/bin/bash
LC_CTYPE=C
export LC_CTYPE

ionice -c3 -p$BASHPID

# Version
version="0.9.4-beta"

# PID
script_pid=$BASHPID

# Serial
for arg in "$@"; do
  if [ -b "$arg" ]; then
    attrs=$(udevadm info --query=property --name="${arg}")
    serial_number=$(echo -e "$attrs" | awk -F'=' '/ID_SCSI_SERIAL/{print $2}')
    if [ -z "$serial_number" ]; then
      serial_number=$(echo -e "$attrs" | awk -F'=' '/ID_SERIAL_SHORT/{print $2}')
    fi
    break
  else
    serial_number=""
  fi
done

# Log prefix
if [ -n "$serial_number" ]; then
  log_prefix="preclear_disk_${serial_number}_${script_pid}:"
else
  log_prefix="preclear_disk_${script_pid}:"
fi

# Redirect errors to log
exec 2> >(while read err; do echo "$(date +"%b %d %T" ) ${log_prefix} ${err}" >> /var/log/preclear.disk.log; echo "${err}"; done; >&2)

debug() {
  cat <<< "$(date +"%b %d %T" ) ${log_prefix} $@" >> /var/log/preclear.disk.log
}

# Let's make sure some features are supported by BASH
BV=$(echo $BASH_VERSION|tr '.' "\n"|grep -Po "^\d+"|xargs printf "%.2d\n"|tr -d '\040\011\012\015')
if [ "$BV" -lt "040253" ]; then
  echo -e "Sorry, your BASH version isn't supported.\nThe minimum required version is 4.2.53.\nPlease update."
  debug "Sorry, your BASH version isn't supported.\nThe minimum required version is 4.2.53.\nPlease update."
  exit 2
fi

# Let's verify all dependencies
for dep in cat awk basename blockdev comm date dd find fold getopt grep kill openssl printf readlink seq sort sum tac tmux todos tput udevadm xargs; do
  if ! type $dep >/dev/null 2>&1 ; then
    echo -e "The following dependency isn't met: [$dep]. Please install it and try again."
    debug "The following dependency isn't met: [$dep]. Please install it and try again."
    exit 1
  fi
done

######################################################
##                                                  ##
##                 PROGRAM FUNCTIONS                ##
##                                                  ##
######################################################

trim() {
  local var="$*"
  var="${var#"${var%%[![:space:]]*}"}"   # remove leading whitespace characters
  var="${var%"${var##*[![:space:]]}"}"   # remove trailing whitespace characters
  echo -n "$var"
}

debug() {
  cat <<< "$(date +"%b %d %T" ) ${log_prefix} $@" >> /var/log/preclear.disk.log
}

list_unraid_disks(){
  local _result=$1
  local i=0
  # Get flash disk device
  unraid_disks[$i]=$(readlink -f /dev/disk/by-label/UNRAID|grep -Po "[^\d]*")

  # Grab cache disks using disks.cfg file
  if [ -f "/boot/config/disk.cfg" ]
  then
    while read line ; do
      if [ -n "$line" ]; then
        let "i+=1" 
        unraid_disks[$i]=$(find /dev/disk/by-id/ -type l -iname "*-$line*" ! -iname "*-part*"| xargs readlink -f)
      fi
    done < <(cat /boot/config/disk.cfg|grep 'cacheId'|grep -Po '=\"\K[^\"]*')
  fi

  # Get array disks using super.dat id's
  if [ -f "/var/local/emhttp/disks.ini " ]; then
    while read line; do
      disk="/dev/${line}"
      if [ -n "$disk" ]; then
        let "i+=1"
        unraid_disks[$i]=$(readlink -f $disk)
      fi
    done < <(cat /var/local/emhttp/disks.ini | grep -Po 'device="\K[^"]*')
  fi
  eval "$_result=(${unraid_disks[@]})"
}

list_all_disks(){
  local _result=$1
  for disk in $(find /dev/disk/by-id/ -type l ! \( -iname "wwn-*" -o -iname "*-part*" \))
  do
    all_disks+=($(readlink -f $disk))
  done
  eval "$_result=(${all_disks[@]})"
}

is_preclear_candidate () {
  list_unraid_disks unraid_disks
  part=($(comm -12 <(for X in "${unraid_disks[@]}"; do echo "${X}"; done|sort)  <(echo $1)))
  if [ ${#part[@]} -eq 0 ] && [ $(cat /proc/mounts|grep -Poc "^${1}") -eq 0 ]
  then
    return 0
  else
    return 1
  fi
}

# list the disks that are not assigned to the array. They are the possible drives to pre-clear
list_device_names() {
  echo "====================================$ver"
  echo " Disks not assigned to the unRAID array "
  echo "  (potential candidates for clearing) "
  echo "========================================"
  list_unraid_disks unraid_disks
  list_all_disks all_disks
  unassigned=($(comm -23 <(for X in "${all_disks[@]}"; do echo "${X}"; done|sort)  <(for X in "${unraid_disks[@]}"; do echo "${X}"; done|sort)))

  if [ ${#unassigned[@]} -gt 0 ]
  then
    for disk in "${unassigned[@]}"
    do
      if [ $(cat /proc/mounts|grep -Poc "^${disk}") -eq 0 ]
      then
        serial=$(udevadm info --query=property --path $(udevadm info -q path -n $disk 2>/dev/null) 2>/dev/null|grep -Po "ID_SERIAL=\K.*")
        echo "     ${disk} = ${serial}"
      fi
    done
  else
    echo "No un-assigned disks detected."
  fi
}

# gfjardim - add notification system capability without breaking legacy mail.
send_mail() {
  subject=$(echo ${1} | tr "'" '`' )
  description=$(echo ${2} | tr "'" '`' )
  message=$(echo ${3} | tr "'" '`' )
  recipient=${4}
  if [ -n "${5}" ]; then
    importance="${5}"
  else
    importance="normal"
  fi
  if [ -f "/usr/local/sbin/notify" ]; then # unRAID 6.0
    notify_script="/usr/local/sbin/notify"
  elif [ -f "/usr/local/emhttp/plugins/dynamix/scripts/notify" ]; then # unRAID 6.1
    notify_script="/usr/local/emhttp/plugins/dynamix/scripts/notify"
  else # unRAID pre 6.0
    return 1
  fi
  $notify_script -e "Preclear ${model} ${serial}" -s """${subject}""" -d """${description}""" -m """${message}""" -i "${importance} ${notify_channel}"
}

append() {
  local _array=$1 _key;
  eval "local x=\${${1}+x}"
  if [ -z $x ]; then
    declare -g -A $1
  fi
  if [ "$#" -eq "3" ]; then
    el=$(printf "[$2]='%s'" "${@:3}")
  else
    for (( i = 0; i < 1000; i++ )); do
      eval "_key=\${$_array[$i]+x}"
      if [ -z "$_key" ] ; then
        break
      fi
    done
    el="[$i]=\"${@:2}\""
  fi
  eval "$_array+=($el)"; 
}

array_enumerate() {
  local i _column z
  for z in $@; do
    echo -e "array '$z'\n ("
    eval "_column="";for i in \"\${!$z[@]}\"; do  _column+=\"| | [\$i]| -> |\${$z[\$i]}\n\"; done"
    echo -e $_column|column -t -s "|"
    echo -e " )\n"
  done
}

array_content() { local _arr=$(eval "declare -p $1") && echo "${_arr#*=}"; }

read_mbr() {
  # called read_mbr [variable] "/dev/sdX" 
  local result=$1 disk=$2 i
  # verify MBR boot area is clear
  append mbr `dd bs=446 count=1 if=$disk 2>/dev/null        |sum|awk '{print $1}'`
  array_enumerate mbr
  # verify partitions 2,3, & 4 are cleared
  append mbr `dd bs=1 skip=462 count=48 if=$disk 2>/dev/null|sum|awk '{print $1}'`
  array_enumerate mbr
  # verify partition type byte is clear
  append mbr `dd bs=1 skip=450 count=1 if=$disk  2>/dev/null|sum|awk '{print $1}'`
  array_enumerate mbr

  # verify MBR signature bytes are set as expected
  append mbr `dd bs=1 count=1 skip=511 if=$disk 2>/dev/null |sum|awk '{print $1}'`
  array_enumerate mbr

  append mbr `dd bs=1 count=1 skip=510 if=$disk 2>/dev/null |sum|awk '{print $1}'`

  for i in $(seq 446 461); do
    append mbr `dd bs=1 count=1 skip=$i if=$disk 2>/dev/null|sum|awk '{print $1}'`
  done
  echo $(declare -p mbr)
}

verify_mbr() {
  # called verify_mbr "/dev/disX"
  local cleared
  local disk=$1
  local disk_blocks=${disk_properties[blocks_512]}
  local i
  local max_mbr_blocks
  local mbr_blocks
  local over_mbr_size
  local partition_size
  local patterns
  declare sectors
  local start_sector 
  local patterns=("00000" "00000" "00000" "00170" "00085")
  local max_mbr_blocks=$(printf "%d" 0xFFFFFFFF)

  if [ $disk_blocks -ge $max_mbr_blocks ]; then
    over_mbr_size="y"
    patterns+=("00000" "00000" "00002" "00000" "00000" "00255" "00255" "00255")
    partition_size=$(printf "%d" 0xFFFFFFFF)
  else
    patterns+=("00000" "00000" "00000" "00000" "00000" "00000" "00000" "00000")
    partition_size=$disk_blocks
  fi

  array=$(read_mbr sectors "$disk")
  eval "declare -A sectors="${array#*=}

  for i in $(seq 0 $((${#patterns[@]}-1)) ); do
    if [ "${sectors[$i]}" != "${patterns[$i]}" ]; then
      echo "Failed test 1: MBR signature is not valid. [${sectors[$i]}] != [${patterns[$i]}]"
      return 1
    fi
  done

  for i in $(seq ${#patterns[@]} $((${#sectors[@]}-1)) ); do
    if [ $i -le 16 ]; then
      start_sector="$(echo ${sectors[$i]}|awk '{printf("%02x", $1)}')${start_sector}"
    else
      mbr_blocks="$(echo ${sectors[$i]}|awk '{printf("%02x", $1)}')${mbr_blocks}"
    fi
  done

  start_sector=$(printf "%d" "0x${start_sector}")
  mbr_blocks=$(printf "%d" "0x${mbr_blocks}")

  case "$start_sector" in
    63) 
      let partition_size=($disk_blocks - $start_sector)
      ;;
    64)
      let partition_size=($disk_blocks - $start_sector)
      ;;
    1)
      if [ "$over_mbr_size" != "y" ]; then
        echo "Failed test 2: GPT start sector [$start_sector] is wrong, should be [1]."
        return 1
      fi
      ;;
    *)
      echo "Failed test 3: start sector is different from those accepted by unRAID."
      ;;
  esac
  if [ $partition_size -ne $mbr_blocks ]; then
    echo "Failed test 4: physical size didn't match MBR declared size. [$partition_size] != [$mbr_blocks]"
    return 1
  fi
  return 0
}


write_signature() {
  local disk=${disk_properties[device]}
  local disk_blocks=${disk_properties[blocks_512]} 
  local max_mbr_blocks partition_size size1=0 size2=0 sig start_sector=$1 var
  let partition_size=($disk_blocks - $start_sector)
  max_mbr_blocks=$(printf "%d" 0xFFFFFFFF)
  
  if [ $disk_blocks -ge $max_mbr_blocks ]; then
    size1=$(printf "%d" "0x00020000")
    size2=$(printf "%d" "0xFFFFFF00")
    start_sector=1
    partition_size=$(printf "%d" 0xFFFFFFFF)
  fi

  dd if=/dev/zero bs=512 seek=1 of=$disk  count=4096 2>/dev/null
  dd if=/dev/zero bs=1 seek=462 count=48 of=$disk >/dev/null 2>&1
  dd if=/dev/zero bs=446 count=1 of=$disk  >/dev/null 2>&1
  echo -ne "\0252" | dd bs=1 count=1 seek=511 of=$disk >/dev/null 2>&1
  echo -ne "\0125" | dd bs=1 count=1 seek=510 of=$disk >/dev/null 2>&1

  for var in $size1 $size2 $start_sector $partition_size ; do
    for hex in $(tac <(fold -w2 <(printf "%08x\n" $var) )); do
      sig="${sig}\\x${hex}"
      # sig="${sig}$(printf '\\x%02x' "0x${hex}")"
    done
  done
  printf $sig| dd seek=446 bs=1 count=16 of=$disk >/dev/null 2>&1
}

maxExecTime() {
  # maxExecTime prog_name disk_name max_exec_time
  exec_time=0
  prog_name=$1
  disk_name=$(basename $2)
  max_exec_time=$3

  while read line; do
    pid=$( echo $line | awk '{print $1}')
    pid_time=$(find /proc/${pid} -maxdepth 0 -type d -printf "%a\n" 2>/dev/null)
    pid_child=$(ps -h --ppid ${pid} 2>/dev/null | wc -l)
    # pid_child=0
    if [ -n "$pid_time" -a "$pid_child" -eq 0 ]; then
      let "pid_time=$(date +%s) - $(date +%s -d "$pid_time")"
      if [ "$pid_time" -gt "$exec_time" ]; then
        exec_time=$pid_time
        debug "${prog_name} exec_time: ${exec_time}s"
      fi
      if [ "$pid_time" -gt $max_exec_time ]; then
        debug "killing ${prog_name} with pid ${pid} - probably stalled..." 
        kill -9 $pid &>/dev/null
      fi
    fi
  done < <(ps ax -o pid,cmd | awk '/'$prog_name'.*\/dev\/'${disk_name}'/{print $1}' )
  echo $exec_time
}


write_disk(){
  # called write_disk
  local bytes_wrote=0
  local bytes_dd
  local bytes_dd_current=0
  local cycle=$cycle
  local cycles=$cycles
  local current_speed
  local dd_flags="conv=noerror,notrunc oflag=direct"
  local dd_hang=0
  local dd_last_bytes=0
  local dd_pid
  local dd_output=${all_files[dd_out]}
  local disk=${disk_properties[device]}
  local disk_name=${disk_properties[name]}
  local disk_blocks=${disk_properties[blocks]}
  local pause=${all_files[pause]}
  local paused_file=n
  local paused_smart=n
  local paused_sync=n
  local percent_wrote
  local percent_pause=0
  local short_test=$short_test
  local stat_file=${all_files[stat]}
  local tb_formatted
  local total_bytes
  local write_bs=""
  local time_start
  local display_pid=0
  local write_bs=2097152

  local write_type=$1
  local initial_bytes=$2
  local initial_timer=$3
  local output=$4
  local output_speed=$5

  # start time
  resume_timer=${!initial_timer}
  resume_timer=${resume_timer:-0}
  if [ "$resume_timer" -gt "0" ]; then
    time_start=$(( $(date '+%s') - $resume_timer ))
  else
    time_start=$(timer)
  fi

  touch $dd_output

  # Seek if restored
  resume_seek=${!initial_bytes:-0}
  resume_seek=${resume_seek:-0}
  if [ "$resume_seek" -gt "$write_bs" ]; then
    resume_seek=$(($resume_seek - $write_bs))
    debug "Continuing disk write on byte $resume_seek"
    dd_flags="$dd_flags oflag=seek_bytes"
    dd_seek="seek=$resume_seek"
  else
    dd_seek="seek=1"
  fi

  # Type of write: zero or random
  if [ "$write_type" == "zero" ]; then
    write_type_s="Zeroing"
    device="/dev/zero"
    dd_cmd="dd if=$device of=$disk bs=$write_bs $dd_seek"
  else
    write_type_s="Erasing"
    device="/dev/urandom"
    pass=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 -w 0)
    dd_cmd="openssl enc -aes-256-ctr -pass pass:'${pass}' -nosalt < /dev/zero 2>/dev/null | dd of=${disk} bs=${write_bs} $dd_seek iflag=fullblock"
  fi

  if [ "$short_test" == "y" ]; then
    total_bytes=$(($write_bs * 2048))
    dd_cmd="${dd_cmd} count=$(($total_bytes / $write_bs)) ${dd_flags}"
  else
    total_bytes=${disk_properties[size]}
    dd_cmd="${dd_cmd} ${dd_flags}"
  fi
  tb_formatted=$(format_number $total_bytes)

  # Empty the MBR partition table
  dd if=$device bs=512 count=4096 of=$disk >/dev/null 2>&1
  blockdev --rereadpt $disk

  dd_cmd="ionice -c 3 ${dd_cmd}"

  debug "${write_type_s}: $dd_cmd"
  eval "$dd_cmd 2>$dd_output &"
  block_pid=$!

  for i in $(seq 5); do
    dd_pid=$(ps --ppid $script_pid | awk '/dd/{print $1}')
    if [ -n "$dd_pid" ]; then
      break;
    else
      sleep 1
    fi
  done

  debug "${write_type_s}: dd pid [$dd_pid]"

  sleep 1

  # return 1 if dd failed
  if ! ps -p $dd_pid &>/dev/null; then
    debug "${write_type_s}: dd command failed -> $(cat $dd_output)"
    return 1
  fi

  # if we are interrupted, kill the background zeroing of the disk.
  trap 'kill -9 $dd_pid 2>/dev/null;exit' EXIT

  # Send initial notification
  if [ "$notify_channel" -gt 0 ] && [ "$notify_freq" -ge 3 ] ; then
    report_out="${write_type_s} Started on $disk_name.\\n Disk temperature: $(get_disk_temp $disk "$smart_type")\\n"
    send_mail "${write_type_s} Started on $disk_name." "${write_type_s} Started on $disk_name. Cycle $cycle of ${cycles}. " "$report_out"
    next_notify=25
  fi

  while kill -0 $dd_pid &>/dev/null; do
    sleep 5 && kill -USR1 $dd_pid 2>/dev/null && sleep 2
    # Calculate the current status
    bytes_dd=$(awk 'END{print $1}' $dd_output|xargs)

    # Ensure bytes_wrote is a number
    if [ ! -z "${bytes_dd##*[!0-9]*}" ]; then
      bytes_wrote=$(($bytes_dd + $resume_seek))
      bytes_dd_current=$bytes_dd
    fi

    # Detect hung dd write
    if [ "$bytes_wrote" -eq "$dd_last_bytes" -a "$is_paused" != "y" ]; then
      let dd_hang=($dd_hang +1)
    else
      dd_last_bytes=$bytes_wrote
      dd_hang=0
    fi

    # Kill dd if hung
    if [ "$dd_hang" -gt 10 ]; then
      eval "$initial_bytes='$bytes_wrote';"
      eval "$initial_timer='$(( $(date '+%s') - $time_start ))';"
      kill -9 $dd_pid
      return 2
    fi

    # Save current status
    save_current_status "$write_type" "$bytes_wrote" $(( $(date '+%s') - $time_start ))

    let percent_wrote=($bytes_wrote*100/$total_bytes)
    if [ ! -z "${bytes_wrote##*[!0-9]*}" ]; then
      let percent_wrote=($bytes_wrote*100/$total_bytes)
    fi
    time_current=$(timer)

    current_speed=$(awk -F',' 'END{print $NF}' $dd_output|xargs)
    average_speed=$(($bytes_wrote / ($time_current - $time_start) / 1000000 ))

    status="Time elapsed: $(timer $time_start) | Write speed: $current_speed | Average speed: $average_speed MB/s"
    if [ "$cycles" -gt 1 ]; then
      cycle_disp=" ($cycle of $cycles)"
    fi

    echo "$disk_name|NN|${write_type_s}${cycle_disp}: ${percent_wrote}% @ $current_speed ($(timer $time_start))|$$" >$stat_file

    # Pause if requested
    if [ -f "$pause" ]; then
      if [ -f "$pause" -a "$paused_file" != "y" ]; then
        kill -TSTP $dd_pid
        paused_file=y
      fi
    elif [ ! -f "$pause" -a "$paused_file" == "y" ]; then
      kill -CONT $dd_pid
      paused_file=n
    fi

    # Pause if a 'smartctl' command is taking too much time to complete
    maxSmartTime=$(maxExecTime "smartctl" "$disk_name" "60")
    if [ "$maxSmartTime" -gt 30 -a "$paused_smart" != "y" ]; then
      debug "dd[${dd_pid}]: Pausing (smartctl exec time: ${maxSmartTime}s)"
      kill -TSTP $dd_pid
      paused_smart=y
    elif [ "$maxSmartTime" -lt 30 -a "$paused_smart" == "y" ]; then
      debug "dd[${dd_pid}]: resumed"
      kill -CONT $dd_pid
      paused_smart=n
    fi

    # Pause if a 'hdparm' command is taking too much time to complete
    maxHdparmTime=$(maxExecTime "hdparm" "$disk_name" "60")
    if [ "$maxHdparmTime" -gt 30 -a "$paused_hdparm" != "y" ]; then
      debug "dd[${dd_pid}]: Pausing (hdparm exec time: ${maxHdparmTime}s)"
      kill -TSTP $dd_pid
      paused_hdparm=y
    elif [ "$maxHdparmTime" -lt 30 -a "$paused_hdparm" == "y" ]; then
      debug "dd[${dd_pid}]: resumed"
      kill -CONT $dd_pid
      paused_hdparm=n
    fi

    # Pause if a sync command were issued
    isSync=$(ps -e -o pid,command | grep -Po "\d+ [s]ync$" | wc -l)
    if [ "$isSync" -gt 0 -a "$paused_sync" != "y" ]; then
      debug "dd[${dd_pid}]: Pausing (sync command issued)"
      kill -TSTP $dd_pid
      paused_sync=y
    elif [ "$isSync" -eq 0 -a "$paused_sync" == "y" ]; then
      debug "dd[${dd_pid}]: resumed"
      kill -CONT $dd_pid
      paused_sync=n
    fi

    if [ $"$paused_file" == "y" -o "$paused_sync" == "y" -o "$paused_hdparm" == "y" -o "$paused_smart" == "y" ]; then
      echo "$disk_name|NN|${write_type_s}${cycle_disp}: PAUSED|$$" >$stat_file
      display_status "${write_type_s} in progress:|###(${percent_wrote}% Done)### ***PAUSED***" "** PAUSED"
      display_pid=$!
      is_paused=y
    else
      # Display refresh
      if [ ! -e "/proc/${display_pid}/exe" ]; then
        display_status "${write_type_s} in progress:|###(${percent_wrote}% Done)###" "** $status" &
        display_pid=$!
      fi
      is_paused=n
    fi

    # Send mid notification
    if [ "$notify_channel" -gt 0 ] && [ "$notify_freq" -eq 4 ] && [ "$percent_wrote" -ge "$next_notify" ] && [ "$percent_wrote" -ne 100 ]; then
      disktemp="$(get_disk_temp $disk "$smart_type")"
      report_out="${write_type_s} in progress on $disk_name: ${percent_wrote}% complete.\\n"
      report_out+="Wrote $(format_number ${bytes_wrote}) of ${tb_formatted} @ ${current_speed} \\n"
      report_out+="Disk temperature: ${disktemp}\\n"
      report_out+="Cycle's Elapsed Time: $(timer ${cycle_timer})\\n"
      report_out+="Total Elapsed time: $(timer ${all_timer})"
      send_mail "${write_type_s} in Progress on ${disk_name}." "${write_type_s} in Progress on ${disk_name}: ${percent_wrote}% @ ${current_speed}. Temp: ${disktemp}. Cycle ${cycle} of ${cycles}." "${report_out}"
      let next_notify=($next_notify + 25)
    fi
  done

  wait $dd_pid;
  dd_exit=$?

  bytes_dd=$(awk 'END{print $1}' $dd_output|xargs)
  if [ ! -z "${bytes_dd##*[!0-9]*}" ]; then
    bytes_wrote=$(( $bytes_dd + $resume_seek + $write_bs ))
  fi

  debug "${write_type_s}: dd - wrote ${bytes_wrote} of ${total_bytes}."

  # Wait last display refresh
  while kill -0 $display_pid &>/dev/null; do
    sleep 1
  done

  # Exit if dd failed
  debug "${write_type_s}: $dd_exit"

  # Send final notification
  if [ "$notify_channel" -gt 0 ] && [ "$notify_freq" -ge 3 ] ; then
    report_out="${write_type_s} finished on $disk_name.\\n"
    report_out+="Wrote $(format_number ${bytes_wrote}) of ${tb_formatted} @ ${current_speed} \\n"
    report_out+="Disk temperature: $(get_disk_temp $disk "$smart_type").\\n"
    report_out+="${write_type_s} Elapsed Time: $(timer $time_start).\\n"
    report_out+="Cycle's Elapsed Time: $(timer $cycle_timer).\\n"
    report_out+="Total Elapsed time: $(timer $all_timer)."
    send_mail "${write_type_s} Finished on $disk_name." "${write_type_s} Finished on $disk_name. Cycle ${cycle} of ${cycles}." "$report_out"
  fi

  eval "$output='$(timer $time_start) @ $average_speed MB/s';$output_speed='$average_speed MB/s'"
}

format_number() {
  echo " $1 " | sed -r ':L;s=\b([0-9]+)([0-9]{3})\b=\1,\2=g;t L'|xargs
}

# Keep track of the elapsed time of the preread/clear/postread process
timer() {
  if [[ $# -eq 0 ]]; then
    echo $(date '+%s')
  else
    local  stime=$1
    etime=$(date '+%s')

    if [[ -z "$stime" ]]; 
      then stime=$etime; 
    fi

    dt=$((etime - stime))
    ds=$((dt % 60))
    dm=$(((dt / 60) % 60))
    dh=$((dt / 3600))
    printf '%d:%02d:%02d' $dh $dm $ds
  fi
}

is_numeric() {
  local _var=$2 _num=$3
  if [ ! -z "${_num##*[!0-9]*}" ]; then
    eval "$1=$_num"
  else
    echo "$_var value [$_num] is not a number. Please verify your commad arguments.";
    exit 2
  fi
}

save_current_status() {
  local current_op=$1
  local current_pos=$2
  local current_timer=$3

  echo -e "current_op=$current_op" > ${all_files[dir]}/resume
  echo -e "current_pos=$current_pos" >> ${all_files[dir]}/resume
  echo -e "current_timer=$current_timer" >> ${all_files[dir]}/resume
  echo -e "current_cycle=$cycle" >> ${all_files[dir]}/resume
  echo -e "all_timer_diff=$(( $(date '+%s') - $all_timer ))" >> ${all_files[dir]}/resume
  echo -e "cycle_timer_diff=$(( $(date '+%s') - $cycle_timer ))" >> ${all_files[dir]}/resume

  echo -e "notify_freq=$notify_freq" >> ${all_files[dir]}/resume
  echo -e "notify_channel=$notify_channel" >> ${all_files[dir]}/resume
  echo -e "short_test=$short_test" >> ${all_files[dir]}/resume
  echo -e "skip_preread=$skip_preread" >> ${all_files[dir]}/resume
  echo -e "skip_postread=$skip_postread" >> ${all_files[dir]}/resume
  echo -e "read_size=$read_size" >> ${all_files[dir]}/resume
  echo -e "write_size=$write_size" >> ${all_files[dir]}/resume
  echo -e "read_blocks=$read_blocks" >> ${all_files[dir]}/resume
  echo -e "read_stress=$read_stress" >> ${all_files[dir]}/resume
  echo -e "cycles=$cycles" >> ${all_files[dir]}/resume
  echo -e "no_prompt=$no_prompt" >> ${all_files[dir]}/resume
  echo -e "erase_disk=$erase_disk" >> ${all_files[dir]}/resume
  echo -e "erase_preclear=$erase_preclear" >> ${all_files[dir]}/resume
  echo -e "preread_average='$preread_average'" >> ${all_files[dir]}/resume
  echo -e "preread_speed='$preread_speed'" >> ${all_files[dir]}/resume
  echo -e "write_average='$write_average'" >> ${all_files[dir]}/resume
  echo -e "write_speed='$write_speed'" >> ${all_files[dir]}/resume
  echo -e "postread_average='$postread_average'" >> ${all_files[dir]}/resume
  echo -e "postread_speed='$postread_speed'" >> ${all_files[dir]}/resume
  cp ${all_files[dir]}/resume ${all_files[resume_file]}
}

read_entire_disk() { 
  local average_speed bytes_dd current_speed count disktemp dd_cmd resume_skip report_out status tb_formatted
  local skip_b1 skip_b2 skip_b3 skip_p1 skip_p2 skip_p3 skip_p4 skip_p5 time_start time_current read_type_s read_type_t total_bytes
  local bytes_read=0
  local bytes_dd_current=0
  local cmp_output=${all_files[cmp_out]}
  local cycle=$cycle
  local cycles=$cycles
  local display_pid=0
  local dd_flags="conv=notrunc,noerror iflag=direct"
  local dd_hang=0
  local dd_last_bytes=0
  local dd_output=${all_files[dd_out]}
  local dd_seek=""
  local disk=${disk_properties[device]}
  local disk_name=${disk_properties[name]}
  local disk_blocks=${disk_properties[blocks_512]}
  local pause=${all_files[pause]}
  local paused_file=n
  local paused_smart=n
  local paused_sync=n
  local percent_read=0
  local read_stress=$read_stress
  local short_test=$short_test
  local stat_file=${all_files[stat]}
  local verify_errors=${all_files[verify_errors]}
  local read_bs=2097152

  local verify=$1
  local read_type=$2
  local initial_bytes=$3
  local initial_timer=$4
  local output=$5
  local output_speed=$6

  # start time
  resume_timer=${!initial_timer}
  resume_timer=${resume_timer:-0}
  if [ "$resume_timer" -gt "0" ]; then
    time_start=$(( $(date '+%s') - $resume_timer ))
  else
    time_start=$(timer)
  fi

  # Seek if restored
  resume_skip=${!initial_bytes}
  resume_skip=${resume_skip:-0}
  if [ "$resume_skip" -gt "$read_bs" ]; then
    resume_skip=$(($resume_skip - $read_bs))
    debug "Continuing disk read from byte $resume_skip"
    dd_flags="$dd_flags iflag=skip_bytes"
    dd_skip="skip=$resume_skip"
  else
    dd_skip="skip=1"
  fi

  # Type of read: Pre-Read or Post-Read
  if [ "$read_type" == "preread" ]; then
    read_type_t="Pre-read in progress:"
    read_type_s="Pre-Read"
  elif [ "$read_type" == "postread" ]; then
    read_type_t="Post-Read in progress:"
    read_type_s="Post-Read"
  else
    read_type_t="Verifying if disk is zeroed:"
    read_type_s="Verify Zeroing"
    read_stress=n
  fi

  if [ "$short_test" == "y" ]; then
    total_bytes=$(($read_bs * 2048))
    count="count=$(($total_bytes / $read_bs))"
  else
    total_bytes=${disk_properties[size]}
    count=""
  fi

  tb_formatted=$(format_number $total_bytes)

  # Send initial notification
  if [ "$notify_channel" -gt 0 ] && [ "$notify_freq" -ge 3 ] ; then
    report_out="$read_type_s Started on $disk_name.\\n Disk temperature: $(get_disk_temp $disk "$smart_type")\\n"
    send_mail "$read_type_s Started on $disk_name." "$read_type_s Started on $disk_name. Cycle $cycle of ${cycles}. " "$report_out" &
    next_notify=25
  fi

  # Start the disk read
  if [ "$verify" == "verify" ]; then

    # Verify the beginning of the disk skipping the MBR
    dd_cmd="dd if=$disk bs=512 count=4096 skip=1 conv=notrunc,noerror iflag=direct"
    debug "${read_type_s}: $dd_cmd  2>$dd_output | cmp - /dev/zero &>$cmp_output"
    $dd_cmd 2>$dd_output | cmp - /dev/zero &>$cmp_output
    debug "${read_type_s}: dd pid [$!]"

    # Fail if not zeroed or error
    if grep -q "differ" "$cmp_output" &>/dev/null; then
      debug "${read_type_s}: fail - disk not zeroed"
      return 1
    fi
    
    # Verify the rest of the disk
    dd_cmd="dd if=$disk bs=$read_bs $count $dd_skip $dd_seek $dd_flags 2>$dd_output | cmp - /dev/zero &>$cmp_output"
    debug "${read_type_s}: $dd_cmd"
    dd if=$disk bs=$read_bs $count $dd_skip $dd_seek $dd_flags 2>$dd_output | cmp - /dev/zero &>$cmp_output &
    block_pid=$!

    # get pid of dd
    for i in $(seq 5); do
      dd_pid=$(ps --ppid $script_pid | awk '/dd/{print $1}')
      if [ -n "$dd_pid" ]; then
        break;
      else
        sleep 1
      fi
    done

    if [ -z "$dd_pid" ]; then
      debug "${read_type_s}: dd command failed -> $(cat $dd_output)"
      return 1
    fi

  else
    dd_cmd="dd if=$disk of=/dev/null bs=$read_bs $count $dd_skip $dd_seek $dd_flags"
    debug "${read_type_s}: $dd_cmd"
    $dd_cmd > $dd_output 2>&1 &
    dd_pid=$!
  fi

  debug "${read_type_s}: dd pid [$dd_pid]"

  sleep 1

  # return 1 if dd failed
  if ! ps -p $dd_pid &>/dev/null; then
    debug "${read_type_s}: dd command failed -> $(cat $dd_output)"
    return 1
  fi

  # if we are interrupted, kill the background reading of the disk.
  trap 'kill -9 $dd_pid 2>/dev/null;exit' 2

  while kill -0 $dd_pid >/dev/null 2>&1; do

    # Stress the disk header
    if [ "$read_stress" == "y" ]; then
      # read a random block
      skip_b1=$(( 0+(`head -c4 /dev/urandom| od -An -tu4`)%($disk_blocks) ))
      dd if=$disk of=/dev/null count=1 bs=512 skip=$skip_b1 iflag=direct >/dev/null 2>&1 &
      skip_p1=$!

      # read the first block
      dd if=$disk of=/dev/null count=1 bs=512 iflag=direct >/dev/null 2>&1 &
      skip_p2=$!

      # read a random block
      skip_b2=$(( 0+(`head -c4 /dev/urandom| od -An -tu4`)%($disk_blocks) ))
      dd if=$disk of=/dev/null count=1 bs=512 skip=$skip_b2 iflag=direct >/dev/null 2>&1 &
      skip_p3=$!

      # read the last block
      dd if=$disk of=/dev/null count=1 bs=512 skip=$(($disk_blocks -1)) iflag=direct >/dev/null 2>&1 &
      skip_p4=$!

      # read a random block
      skip_b3=$(( 0+(`head -c4 /dev/urandom| od -An -tu4`)%($disk_blocks) ))
      dd if=$disk of=/dev/null count=1 bs=512 skip=$skip_b3 iflag=direct >/dev/null 2>&1 &
      skip_p5=$!

      # make sure the background random blocks are read before continuing
      kill -0 $skip_p1 2>/dev/null && wait $skip_p1
      kill -0 $skip_p2 2>/dev/null && wait $skip_p2
      kill -0 $skip_p3 2>/dev/null && wait $skip_p3
      kill -0 $skip_p4 2>/dev/null && wait $skip_p4
      kill -0 $skip_p5 2>/dev/null && wait $skip_p5
    fi

    # Refresh dd status
    sleep 5 && kill -USR1 $dd_pid 2>/dev/null && sleep 2

    # Calculate the current status
    bytes_dd=$(awk 'END{print $1}' $dd_output|xargs)

    # Ensure bytes_read is a number
    if [ ! -z "${bytes_dd##*[!0-9]*}" ]; then
      bytes_read=$(($bytes_dd + $resume_skip))
      bytes_dd_current=$bytes_dd
      let percent_read=($bytes_read*100/$total_bytes)
    fi

    # Detect hung dd read
    if [ "$bytes_read" == "$dd_last_bytes" -a "$is_paused" != "y" ]; then
      dd_hang=$(($dd_hang + 1))
    else
      dd_hang=0
      dd_last_bytes=$bytes_read
    fi

    # Kill dd if hung
    if [ "$dd_hang" -gt 10 ]; then
      eval "$initial_bytes='"$bytes_read"';"
      eval "$initial_timer='$(( $(date '+%s') - $time_start ))';"
      kill -9 $dd_pid
      return 2
    fi

    # Save current status
    save_current_status "$read_type" "$bytes_read" $(( $(date '+%s') - $time_start ))

    time_current=$(timer)

    current_speed=$(awk -F',' 'END{print $NF}' $dd_output|xargs)
    average_speed=$(($bytes_read / ($time_current - $time_start) / 1000000 ))

    status="Time elapsed: $(timer $time_start) | Current speed: $current_speed | Average speed: $average_speed MB/s"
    if [ "$cycles" -gt 1 ]; then
      cycle_disp=" ($cycle of $cycles)"
    fi
    echo "$disk_name|NN|${read_type_s}${cycle_disp}: ${percent_read}% @ ${average_speed} MB/s ($(timer $time_start))|$$" > $stat_file

    if [ "$paused_file" == "y" -o "$paused_sync" == "y" -o "$paused_hdparm" == "y" -o "$paused_smart" == "y" ]; then
      echo "$disk_name|NN|${read_type_t}${cycle_disp} PAUSED|$$" >$stat_file
      display_status "${read_type_t}|###(${percent_read}% Done)### ***PAUSED***" "** PAUSED"
      display_pid=$!
      is_paused=y
    else
      # Display refresh
      if [ ! -e "/proc/${display_pid}/exe" ]; then
        display_status "$read_type_t|###(${percent_read}% Done)###" "** $status" &
        display_pid=$!
      fi
      is_paused=n
    fi

    # Send mid notification
    if [ "$notify_channel" -gt 0 ] && [ "$notify_freq" -eq 4 ] && [ "$percent_read" -ge "$next_notify" ] && [ "$percent_read" -ne 100 ]; then
      disktemp="$(get_disk_temp $disk "$smart_type")"
      report_out="${read_type_s} in progress on $disk_name: ${percent_read}% complete.\\n"
      report_out+="Read $(format_number ${bytes_read}) of ${tb_formatted} @ ${current_speed} \\n"
      report_out+="Disk temperature: ${disktemp}\\n"
      report_out+="Cycle's Elapsed Time: $(timer ${cycle_timer}).\\n"
      report_out+="Total Elapsed time: $(timer ${all_timer})."
      send_mail "$read_type_s in Progress on ${disk_name}." "${read_type_s} in Progress on ${disk_name}: ${percent_read}% @ ${current_speed}. Temp: ${disktemp}. Cycle ${cycle} of ${cycles}." "${report_out}" &
      let next_notify=($next_notify + 25)
    fi

    # Pause if requested
    if [ -f "$pause" ]; then
      if [ "$paused_file" != "y" ]; then
        kill -TSTP $dd_pid
        paused_file=y
      fi
    elif [ ! -f "$pause" -a "$paused_file" == "y" ]; then
      kill -CONT $dd_pid
      paused_file=n
    fi

    maxTimeout=15
    
    # Pause if a 'smartctl' command is taking too much time to complete
    maxSmartTime=$(maxExecTime "smartctl" "$disk_name" "60")
    if [ "$maxSmartTime" -gt "$maxTimeout" -a "$paused_smart" != "y" ]; then
      debug "dd[${dd_pid}]: pausing (smartctl exec time: ${maxSmartTime}s)"
      kill -TSTP $dd_pid
      paused_smart=y
    elif [ "$maxSmartTime" -lt "$maxTimeout" -a "$paused_smart" == "y" ]; then
      debug "dd[${dd_pid}]: resumed"
      kill -CONT $dd_pid
      paused_smart=n
    fi

    # Pause if a 'hdparm' command is taking too much time to complete
    maxHdparmTime=$(maxExecTime "hdparm" "$disk_name" "60")
    if [ "$maxHdparmTime" -gt "$maxTimeout" -a "$paused_hdparm" != "y" ]; then
      debug "dd[${dd_pid}]: pausing (hdparm exec time: ${maxHdparmTime}s)"
      kill -TSTP $dd_pid
      paused_hdparm=y
    elif [ "$maxHdparmTime" -lt "$maxTimeout" -a "$paused_hdparm" == "y" ]; then
      debug "dd[${dd_pid}]: resumed"
      kill -CONT $dd_pid
      paused_hdparm=n
    fi

    # Pause if a sync command were issued
    isSync=$(ps -e -o pid,command | grep -Po "\d+ [s]ync$" | wc -l)
    if [ "$isSync" -gt 0 -a "$paused_sync" != "y" ]; then
      debug "dd[${dd_pid}]: pausing (sync command issued)"
      kill -TSTP $dd_pid
      paused_sync=y
    elif [ "$isSync" -eq 0 -a "$paused_sync" == "y" ]; then
      debug "dd[${dd_pid}]: resumed"
      kill -CONT $dd_pid
      paused_sync=n
    fi

  done

  wait $dd_pid;
  dd_exit=$?

  # Wait last display refresh
  while kill -0 $display_pid &>/dev/null; do
    sleep 1
  done

  bytes_dd=$(awk 'END{print $1}' $dd_output|xargs)
  if [ ! -z "${bytes_dd##*[!0-9]*}" ]; then
    bytes_read=$(( $bytes_dd + $resume_skip + $read_bs ))
  fi

  debug "${read_type_s}: dd - read ${bytes_read} of ${total_bytes}."

  debug "${read_type_s}: $dd_exit"

  # Fail if not zeroed or error
  if [ "$verify" == "verify" ]; then
    if grep -q "differ" "$cmp_output" &>/dev/null; then
      debug "${read_type_s}: fail - disk not zeroed"
      return 1
    fi
  fi

  # Send final notification
  if [ "$notify_channel" -gt 0 ] && [ "$notify_freq" -ge 3 ] ; then
    report_out="$read_type_s finished on $disk_name.\\n"
    report_out+="Read $(format_number $bytes_read) of $tb_formatted @ $average_speed MB/s\\n"
    report_out+="Disk temperature: $(get_disk_temp $disk "$smart_type").\\n"
    report_out+="$read_type_s Elapsed Time: $(timer $time_start).\\n"
    report_out+="Cycle's Elapsed Time: $(timer $cycle_timer).\\n"
    report_out+="Total Elapsed time: $(timer $all_timer)."
    send_mail "$read_type_s Finished on $disk_name." "$read_type_s Finished on $disk_name. Cycle ${cycle} of ${cycles}." "$report_out" &
  fi

  eval "$output='$(timer $time_start) @ $average_speed MB/s';$output_speed='$average_speed MB/s'"
  return 0
}

draw_canvas(){
  local start=$1 height=$2 width=$3 brick="${canvas[brick]}" c
  let iniline=($height + $start)
  for line in $(seq $start $iniline ); do
    c+=$(tput cup $line 0 && echo $brick)
    c+=$(tput cup $line $width && echo $brick)
  done
  for col in $(seq $width); do
    c+=$(tput cup $start $col && echo $brick)
    c+=$(tput cup $iniline $col && echo $brick)
    c+=$(tput cup $(( $iniline - 2 )) $col && echo $brick)
  done
  echo $c
}

display_status(){
  local max=$max_steps
  local cycle=$cycle
  local cycles=$cycles
  local current=$1
  local status=$2
  local stat=""
  local width="${canvas[width]}"
  local height="${canvas[height]}"
  local all_timer=$all_timer
  local cycle_timer=$cycle_timer
  local smart_output="${all_files[smart_out]}"
  local wpos=4
  local hpos=1
  local skip_formatting=$3
  local step=1
  local out="${all_files[dir]}/display_out"

  eval "local -A prev=$(array_content display_step)"
  eval "local -A title=$(array_content display_title)"

  echo "" > $out

  if [ "$skip_formatting" != "y" ]; then
    tput reset > $out
  fi

  if [ -z "${canvas[info]}" ]; then
    append canvas "info" "$(draw_canvas $hpos $height $width)"
  fi
  echo "${canvas[info]}" >> $out

  for (( i = 0; i <= ${#title[@]}; i++ )); do
    line=${title[$i]}
    line_num=$(echo "$line"|tr -d "${bold}"|tr -d "${norm}"|tr -d "${ul}"|tr -d "${noul}"|wc -m)
    tput cup $(($i+2+$hpos)) $(( $width/2 - $line_num/2  )) >> $out
    echo "$line" >> $out
  done

  l=$((${#title[@]}+4+$hpos))

  for i in "${!prev[@]}"; do
    if [ -n "${prev[$i]}" ]; then
      line=${prev[$i]}
      stat=""
      if [ "$(echo "$line"|grep -c '|')" -gt "0" -a "$skip_formatting" != "y" ]; then
        stat=$(trim $(echo "$line"|cut -d'|' -f2))
        line=$(trim $(echo "$line"|cut -d'|' -f1))
      fi
      if [ -n "$max" ]; then
        line="Step $step of $max - $line"
      fi
      tput cup $l $wpos >> $out
      echo $line >> $out
      if [ -n "$stat" ]; then
        clean_stat=$(echo "$stat"|sed -e "s|\*\{3\}\([^\*]*\)\*\{3\}|\1|g"|sed -e "s|\#\{3\}\([^\#]*\)\#\{3\}|\1|g")
        stat_num=${#clean_stat}
        if [ "$skip_formatting" != "y" ]; then
          stat=$(echo "$stat"|sed -e "s|\*\{3\}\([^\*]*\)\*\{3\}|${bold}\1${norm}|g"|sed -e "s|\#\{3\}\([^\#]*\)\#\{3\}|${ul}\1${noul}|g")
        fi
        tput cup $l $(($width - $stat_num - $wpos )) >> $out
        echo "$stat" >> $out
      fi
      let "l+=1"
      let "step+=1"
    fi
  done
  if [ -n "$current" ]; then
    line=$current;
    stat=""
    if [ "$(echo "$line"|grep -c '|')" -gt "0" -a "$skip_formatting" != "y" ]; then
      stat=$(echo "$line"|cut -d'|' -f2)
      line=$(echo "$line"|cut -d'|' -f1)
    fi
    if [ -n "$max" ]; then
      line="Step $step of $max - $line"
    fi
    tput cup $l $wpos >> $out
    echo $line >> $out
    if [ -n "$stat" ]; then
      clean_stat=$(echo "$stat"|sed -e "s|\*\{3\}\([^\*]*\)\*\{3\}|\1|g"|sed -e "s|\#\{3\}\([^\#]*\)\#\{3\}|\1|g")
      stat_num=${#clean_stat}
      if [ "$skip_formatting" != "y" ]; then
        stat=$(echo "$stat"|sed -e "s|\*\{3\}\([^\*]*\)\*\{3\}|${bold}\1${norm}|g"|sed -e "s|\#\{3\}\([^\#]*\)\#\{3\}|${ul}\1${noul}|g")
      fi
      tput cup $l $(($width - $stat_num - $wpos )) >> $out
      echo "$stat" >> $out
    fi
    let "l+=1"
  fi
  if [ -n "$status" ]; then
    tput cup $(($height+$hpos-4)) $wpos >> $out
    echo -e "$status" >> $out
  fi

  footer="Total elapsed time: $(timer $all_timer)"
  if [[ -n "$cycle_timer" ]]; then
    footer="Cycle elapsed time: $(timer $cycle_timer) | $footer"
  fi
  footer_num=$(echo "$footer"|sed -e "s|\*\{3\}\([^\*]*\)\*\{3\}|\1|g"|sed -e "s|\#\{3\}\([^\#]*\)\#\{3\}|\1|g"|wc -m)
  tput cup $(( $height + $hpos - 1)) $(( $width/2 - $footer_num/2  )) >> $out
  echo "$footer" >> $out

  if [ -f "$smart_output" ]; then
    echo -e "\n\n\n\n" >> $out
    init=$(($hpos+$height+3))
    if [ -z "${canvas[smart]}" ]; then
      append canvas "smart" "$(draw_canvas $init $height $width)"
    fi
    echo "${canvas[smart]}" >> $out

    line="S.M.A.R.T. Status $type"
    line_num=$(echo "$line"|tr -d "${bold}"|tr -d "${norm}"|tr -d "${ul}"|tr -d "${noul}"|wc -m)
    let l=($init + 2)
    tput cup $(($l)) $(( $width/2 - $line_num/2 )) >> $out
    echo "${ul}$line${noul}" >> $out
    let l+=3
    while read line; do
      tput cup $l $wpos >> $out
      echo -n "$line" >> $out
      echo -e "" >> $out
      let l+=1
    done < <(head -n -1 "$smart_output")
    tput cup $(( $init + $height - 1)) $wpos >> $out
    tail -n 1 "$smart_output" >> $out
    tput cup $(( $init + $height )) $width >> $out
    # echo "π" >> $out
    tput cup $(( $init + $height + 2)) 0 >> $out
  else
    tput cup $(( $height + $hpos )) $width >> $out
    # echo "π" >> $out
    tput cup $(( $height + $hpos + 2 )) 0 >> $out
  fi
  cat $out
}

ask_preclear(){
  local line
  local wpos=4
  local hpos=0
  local max=""
  local width="${canvas[width]}"
  local height="${canvas[height]}"
  eval "local -A title=$(array_content display_title)"
  eval "local -A disk_info=$(array_content disk_properties)"

  tput reset

  draw_canvas $hpos $height $width

  for (( i = 0; i <= ${#title[@]}; i++ )); do
    line=${title[$i]}
    line_num=$(echo "$line"|tr -d "${bold}"|tr -d "${norm}"|tr -d "${ul}"|tr -d "${noul}"|wc -m)
    tput cup $(($i+2+$hpos)) $(( $width/2 - $line_num/2  )); echo "$line"
  done

  l=$((${#title[@]}+5+$hpos))

  if [ -n "${disk_info[family]}" ]; then
    tput cup $l $wpos && echo "Model Family:   ${disk_info[family]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[model]}" ]; then
    tput cup $l $wpos && echo "Device Model:   ${disk_info[model]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[serial]}" ]; then
    tput cup $l $wpos && echo "Serial Number:  ${disk_info[serial]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[size_human]}" ]; then
    tput cup $l $wpos && echo "User Capacity:  ${disk_info[size_human]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[firmware]}" ]; then
    tput cup $l $wpos && echo "Firmware:       ${disk_info[firmware]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[device]}" ]; then
    tput cup $l $wpos && echo "Disk Device:    ${disk_info[device]}"
  fi

  tput cup $(($height - 4)) $wpos && echo "Type ${bold}Yes${norm} to proceed: "
  tput cup $(($height - 4)) $(($wpos+21)) && read answer

  tput cup $(( $height - 1)) $wpos; 

  if [[ "$answer" == "Yes" ]]; then
    tput cup $(( $height + 2 )) 0
    return 0
  else
    echo "Wrong answer. The disk will ${bold}NOT${norm} be precleared."
    tput cup $(( $height + 2 )) 0
    exit 2
  fi
}

save_smart_info() {
  local name=$3
  local device=$1
  local type=$2
  local valid_attributes=" 5 9 183 184 187 190 194 196 197 198 199 "
  local valid_temp=" 190 194 "
  local smart_file="${all_files[smart_prefix]}${name}"
  local found_temp=n
  cat /dev/null > $smart_file

  while read line; do
    attr=$(echo $line | cut -d'|' -f1)
    if [[ $valid_attributes =~ [[:space:]]$attr[[:space:]] ]]; then
      if [[ $valid_temp =~ [[:space:]]$attr[[:space:]] ]]; then
        if [[ $found_temp != "y" ]]; then
          echo $line >> $smart_file
          found_temp=y
        fi
      else
        echo $line >> $smart_file
      fi
    fi
  done < <(timeout -s 9 30 smartctl --all $type $device 2>/dev/null | sed -n "/ATTRIBUTE_NAME/,/^$/p" | \
           grep -v "ATTRIBUTE_NAME" | grep -v "^$" | awk '{ print $1 "|" $2 "|" $10}')
}

compare_smart() {
  local initial="${all_files[smart_prefix]}$1"
  local current="${all_files[smart_prefix]}$2"
  local final="${all_files[smart_final]}"
  local title=$3
  if [ -e "$final" -a -n "$title" ]; then
    sed -i " 1 s/$/|$title/" $final
  elif [ ! -f "$current" ]; then
    echo "ATTRIBUTE|INITIAL" > $final
    current=$initial
  else
    echo "ATTRIBUTE|INITIAL|$title" > $final
  fi

  while read line; do
    attr=$(echo $line | cut -d'|' -f1)
    name=$(echo $line | cut -d'|' -f2)
    name="${attr}-${name}"
    nvalue=$(echo $line | cut -d'|' -f3)
    ivalue=$(cat $initial| grep "^${attr}"|cut -d'|' -f3)
    if [ "$(cat $final 2>/dev/null|grep -c "$name")" -gt "0" ]; then
      sed -i "/^$name/ s/$/|${nvalue}/" $final
    else
      echo "${name}|${ivalue}" >> $final
    fi
  done < <(cat $current)
}

output_smart() {
  local final="${all_files[smart_final]}"
  local output="${all_files[smart_out]}"
  local device=$1
  local type=$2
  nfinal="${final}_$(( $RANDOM * 19318203981230 + 40 ))"
  cp -f "$final" "$nfinal"
  sed -i " 1 s/$/|STATUS/" $nfinal
  status=$(timeout -s 9 30 smartctl --attributes $type $device 2>/dev/null | sed -n "/ATTRIBUTE_NAME/,/^$/p" | \
           grep -v "ATTRIBUTE_NAME" | grep -v "^$" | awk '{print $1 "-" $2 "|" $9 }')
  while read line; do
    attr=$(echo $line | cut -d'|' -f1)
    inival=$(echo "$line" | cut -d'|' -f2)
    lasval=$(echo "$line" | grep -o '[^|]*$')
    let diff=($lasval - $inival)
    if [ "$diff" -gt "0" ]; then
      msg="Up $diff"
    elif [ "$diff" -lt "0" ]; then
      diff=$(echo $diff | sed 's/-//g')
      msg="Down $diff"
    else
      msg="-"
    fi
    stat=$(echo $status|grep -Po "${attr}[^\s]*")
    if [[ $stat =~ FAILING_NOW ]]; then
      msg="$msg|->FAILING NOW!<-"
    elif [[ $stat =~ In_the_past ]]; then
      msg="$msg|->Failed in Past<-"
    fi
    sed -i "/^$attr/ s/$/|${msg}/" $nfinal
  done < <(cat $nfinal | tail -n +2)
  cat $nfinal | column -t -s '|' -o '  '> $output
  timeout -s 9 30 smartctl --health $type $device | sed -n '/SMART DATA SECTION/,/^$/p'| tail -n +2 | head -n 1 >> $output
}

get_disk_temp() {
  local device=$1
  local type=$2
  local valid_temp=" 190 194 "
  local temp=0
  if [ "$disable_smart" == "y" ]; then
    echo "n/a"
    return 0
  fi

  while read line; do
    attr=$(echo $line | cut -d'|' -f1)
    if [[ $valid_temp =~ [[:space:]]$attr[[:space:]] ]]; then
      echo "$(echo $line | cut -d'|' -f3) C"
      return 0
    fi
  done < <(timeout -s 9 30 smartctl --attributes $type $device 2>/dev/null | sed -n "/ATTRIBUTE_NAME/,/^$/p" | \
           grep -v "ATTRIBUTE_NAME" | grep -v "^$" | awk '{ print $1 "|" $2 "|" $10}')
  echo "n/a"
}

save_report() {
  local success=$1
  local preread_speed=${2:-"n/a"}
  local postread_speed=${3:-"n/a"}
  local zeroing_speed=${4:-"n/a"}
  local controller=${disk_properties[controller]}
  local log_entry=$log_prefix
  local size=$(numfmt --to=si --suffix=B --format='%1.f' --round=nearest ${disk_properties[size]})
  local model=${disk_properties[model]}
  local time=$(timer cycle_timer)
  local smart=${disk_properties[smart_type]}
  local form_out=${all_files[form_out]}
  local title="Preclear Disk<br>Send Anonymous Statistics"

  local text="Send <span style='font-weight:bold;'>anonymous</span> statistics (using Google Forms) to the developer, helping on bug fixes, "
  text+="performance tunning and usage statistics that will be open to the community. For detailed information, please visit the "
  text+="<a href='http://lime-technology.com/forum/index.php?topic=39985.0'>support forum topic</a>."

  local log=$(cat "/var/log/preclear.disk.log" | grep -Po "${log_entry} \K.*" | tr '"' "'" | sed ':a;N;$!ba;s/\n/^n/g')

  cat <<EOF |sed "s/^  //g" > /boot/config/plugins/preclear.disk/$(( $RANDOM * $RANDOM * $RANDOM )).sreport

  [report]
  url = "https://docs.google.com/forms/d/e/1FAIpQLSfIzz2yKJknHCrrpw3KmUjlNhbYabDoECq_vVe9XyFeE_gs-w/formResponse"
  title = "${title}"
  text = "${text}"

  [model]
  entry = 'entry.1754350191'
  title = "Disk Model"
  value = "${model}"

  [size]
  entry = 'entry.1497914868'
  title = "Disk Size"
  value = "${size}"

  [controller]
  entry = 'entry.2002415860'
  title = 'Disk Controller'
  value = "${controller}"

  [preread]
  entry  = 'entry.2099803197'
  title = "Pre-Read Average Speed"
  value = ${preread_speed}

  [postread]
  entry = 'entry.1410821652'
  title = "Post-Read Average Speed"
  value = "${postread_speed}"

  [zeroing]
  entry  = 'entry.1433994509'
  title = "Zeroing Average Speed"
  value = "${zeroing_speed}"

  [cycles]
  entry = "entry.765505609"
  title = "Cycles"
  value = "${cycles}"

  [time]
  entry = 'entry.899329837'
  title = "Total Elapsed Time"
  value = "${time}"

  [smart]
  entry = 'entry.1973215494'
  title = "SMART Device Type"
  value = ${smart}

  [success]
  entry = 'entry.704369346'
  title = "Success"
  value = "${success}"

  [log]
  entry = 'entry.1470248957'
  title = "Log"
  value = "${log}"
EOF
}

######################################################
##                                                  ##
##                  PARSE OPTIONS                   ##
##                                                  ##
######################################################

#Defaut values
all_timer_diff=0
cycle_timer_diff=0
command=$(echo "$0 $@")
read_stress=y
cycles=1
append display_step ""
erase_disk=n
erase_preclear=n
initial_bytes=0
verify_mbr_only=n
refresh_period=30
append canvas 'width'  '123'
append canvas 'height' '20'
append canvas 'brick'  '#'
smart_type=auto
notify_channel=0
notify_freq=0
opts_long="frequency:,notify:,skip-preread,skip-postread,read-size:,write-size:,read-blocks:,test,no-stress,list,"
opts_long+="cycles:,signature,verify,no-prompt,version,preclear-only,format-html,erase,erase-clear,load-file:"

OPTS=$(getopt -o f:n:sSr:w:b:tdlc:ujvomera: \
      --long $opts_long -n "$(basename $0)" -- "$@")

if [ "$?" -ne "0" ]; then
  exit 1
fi

eval set -- "$OPTS"
# (set -o >/dev/null; set >/tmp/.init)
while true ; do
  case "$1" in
    -f|--frequency)      is_numeric notify_freq    "$1" "$2"; shift 2;;
    -n|--notify)         is_numeric notify_channel "$1" "$2"; shift 2;;
    -s|--skip-preread)   skip_preread=y;                      shift 1;;
    -S|--skip-postread)  skip_postread=y;                     shift 1;;
    -r|--read-size)      is_numeric read_size      "$1" "$2"; shift 2;;
    -w|--write-size)     is_numeric write_size     "$1" "$2"; shift 2;;
    -b|--read-blocks)    is_numeric read_blocks    "$1" "$2"; shift 2;;
    -t|--test)           short_test=y;                        shift 1;;
    -d|--no-stress)      read_stress=n;                       shift 1;;
    -l|--list)           list_device_names;                   exit 0;;
    -c|--cycles)         is_numeric cycles         "$1" "$2"; shift 2;;
    -u|--signature)      verify_disk_mbr=y;                   shift 1;;
    -p|--verify)         verify_disk_mbr=y;  verify_zeroed=y; shift 1;;
    -j|--no-prompt)      no_prompt=y;                         shift 1;;
    -v|--version)        echo "$0 version: $version"; exit 0; shift 1;;
    -o|--preclear-only)  write_disk_mbr=y;                    shift 1;;
    -m|--format-html)    format_html=y;                       shift 1;;
    -e|--erase)          erase_disk=y;                        shift 1;;
    -r|--erase-clear)    erase_preclear=y;                    shift 1;;
    -a|--load-file)      load_file="$2";                      shift 2;;

    --) shift ; break ;;
    * ) echo "Internal error!" ; exit 1 ;;
  esac
done

if [ ! -b "$1" ]; then
  echo "Disk not set, please verify the command arguments."
  debug "Disk not set, please verify the command arguments."
  exit 1
fi

theDisk=$(echo $1|xargs)

debug "Command: $command"
debug "Preclear Disk Version: ${version}"

if [ -f "$load_file" ] && $(bash -n "$load_file"); then
  debug "Restoring previous instance of preclear"
  . "$load_file"
fi

# diff /tmp/.init <(set -o >/dev/null; set)
# exit 0
######################################################
##                                                  ##
##          SET DEFAULT PROGRAM VARIABLES           ##
##                                                  ##
######################################################

# Disk properties
append disk_properties 'device'      "$theDisk"
append disk_properties 'size'        $(blockdev --getsize64 ${disk_properties[device]} 2>/dev/null)
append disk_properties 'block_sz'    $(blockdev --getpbsz ${disk_properties[device]} 2>/dev/null)
append disk_properties 'blocks'      $(( ${disk_properties[size]} / ${disk_properties[block_sz]} ))
append disk_properties 'blocks_512'  $(blockdev --getsz ${disk_properties[device]} 2>/dev/null)
append disk_properties 'name'        $(basename ${disk_properties[device]} 2>/dev/null)
append disk_properties 'parts'       $(grep -c "${disk_properties[name]}[0-9]" /proc/partitions 2>/dev/null)
append disk_properties 'serial_long' $(udevadm info --query=property --name ${disk_properties[device]} 2>/dev/null|grep -Po 'ID_SERIAL=\K.*')
append disk_properties 'serial'      $(udevadm info --query=property --name ${disk_properties[device]} 2>/dev/null|grep -Po 'ID_SERIAL_SHORT=\K.*')
append disk_properties 'smart_type'  "default"

disk_controller=$(udevadm info --query=property --name ${disk_properties[device]} | grep -Po 'DEVPATH.*0000:\K[^/]*')
append disk_properties 'controller'  "$(lspci | grep -Po "${disk_controller}[^:]*: \K.*")"

if [ "${disk_properties[parts]}" -gt 0 ]; then
  for part in $(seq 1 "${disk_properties[parts]}" ); do
    let "parts+=($(blockdev --getsize64 ${disk_properties[device]}${part} 2>/dev/null) / ${disk_properties[block_sz]})"
  done
  append disk_properties 'start_sector' $(( ${disk_properties[blocks]} - $parts ))
else
  append disk_properties 'start_sector' "0"
fi


# Disable read_stress if preclearing a SSD
discard=$(cat "/sys/block/${disk_properties[name]}/queue/discard_max_bytes")
if [ "$discard" -gt "0" ]; then
  debug "Disk ${theDisk} is a SSD, disabling head stress test." 
  read_stress=n
fi

# Test suitable device type for SMART, and disable it if not found.
disable_smart=y
for type in "" scsi ata auto sat,auto sat,12 usbsunplus usbcypress usbjmicron usbjmicron,x test "sat -T permissive" usbjmicron,p sat,16; do
  if [ -n "$type" ]; then
    type="-d $type"
  fi
  smartInfo=$(timeout -s 9 30 smartctl --all $type "$theDisk" 2>/dev/null)
  if [[ $smartInfo == *"START OF INFORMATION SECTION"* ]]; then

    smart_type=$type

    if [ -z "$type" ]; then
      type='default'
    fi

    debug "S.M.A.R.T. info type: ${type}"

    append disk_properties 'smart_type' "$type"

    if [[ $smartInfo == *"Reallocated_Sector_Ct"* ]]; then
      debug "S.M.A.R.T. attrs type: ${type}"
      disable_smart=n
    fi
    
    while read line ; do
      if [[ $line =~ Model\ Family:\ (.*) ]]; then
        append disk_properties 'family' "$(echo "${BASH_REMATCH[1]}"|xargs)"
      elif [[ $line =~ Device\ Model:\ (.*) ]]; then
        append disk_properties 'model' "$(echo "${BASH_REMATCH[1]}"|xargs)"
      elif [[ $line =~ User\ Capacity:\ (.*) ]]; then
        append disk_properties 'size_human' "$(echo "${BASH_REMATCH[1]}"|xargs)"
      elif [[ $line =~ Firmware\ Version:\ (.*) ]]; then
        append disk_properties 'firmware' "$(echo "${BASH_REMATCH[1]}"|xargs)"
      elif [[ $line =~ Vendor:\ (.*) ]]; then
        append disk_properties 'vendor' "$(echo "${BASH_REMATCH[1]}"|xargs)"
      elif [[ $line =~ Product:\ (.*) ]]; then
        append disk_properties 'product' "$(echo "${BASH_REMATCH[1]}"|xargs)"
      fi
    done < <(echo -n "$smartInfo")

    if [ -z "${disk_properties[model]}" ] && [ -n "${disk_properties[vendor]}" ] && [ -n "${disk_properties[product]}" ]; then
      append disk_properties 'model' "${disk_properties[vendor]} ${disk_properties[product]}"
    fi

    append disk_properties 'temp' "$(get_disk_temp $theDisk "$smart_type")"

    break
  fi
done

# Used files
append all_files 'dir'           "/tmp/.preclear/${disk_properties[name]}"
append all_files 'dd_out'        "${all_files[dir]}/dd_output"
append all_files 'cmp_out'       "${all_files[dir]}/cmp_out"
append all_files 'pause'         "${all_files[dir]}/pause"
append all_files 'verify_errors' "${all_files[dir]}/verify_errors"
append all_files 'pid'           "${all_files[dir]}/pid"
append all_files 'stat'          "/tmp/preclear_stat_${disk_properties[name]}"
append all_files 'smart_prefix'  "${all_files[dir]}/smart_"
append all_files 'smart_final'   "${all_files[dir]}/smart_final"
append all_files 'smart_out'     "${all_files[dir]}/smart_out"
append all_files 'form_out'      "${all_files[dir]}/form_out"
append all_files 'resume_file'   "/boot/config/plugins/preclear.disk/${disk_properties[serial]}.resume"

mkdir -p "${all_files[dir]}"
# trap "rm -rf ${all_files[dir]}" EXIT;

# Set terminal variables
if [ "$format_html" == "y" ]; then
  clearscreen=`tput clear`
  goto_top=`tput cup 0 1`
  screen_line_three=`tput cup 3 1`
  bold="&lt;b&gt;"
  norm="&lt;/b&gt;"
  ul="&lt;span style=\"text-decoration: underline;\"&gt;"
  noul="&lt;/span&gt;"
elif [ -x /usr/bin/tput ]; then
  clearscreen=`tput clear`
  goto_top=`tput cup 0 1`
  screen_line_three=`tput cup 3 1`
  bold=`tput smso`
  norm=`tput rmso`
  ul=`tput smul`
  noul=`tput rmul`
else
  clearscreen=`echo -n -e "\033[H\033[2J"`
  goto_top=`echo -n -e "\033[1;2H"`
  screen_line_three=`echo -n -e "\033[4;2H"`
  bold=`echo -n -e "\033[7m"`
  norm=`echo -n -e "\033[27m"`
  ul=`echo -n -e "\033[4m"`
  noul=`echo -n -e "\033[24m"`
fi

# set init timer
all_timer=$(timer)

# set the default canvas
# draw_canvas $canvas_height $canvas_width >/dev/null

######################################################
##                                                  ##
##                MAIN PROGRAM BLOCK                ##
##                                                  ##
######################################################

# Verify if it's already running
if [ -f "${all_files[pid]}" ]; then
  pid=$(cat ${all_files[pid]})
  if [ -e "/proc/${pid}" ]; then
    echo "An instance of Preclear for disk '$theDisk' is already running."
    debug "An instance of Preclear for disk '$theDisk' is already running."
    trap '' EXIT
    exit 1
  else
    echo "$$" > ${all_files[pid]}
  fi
else
  echo "$$" > ${all_files[pid]}
fi

if ! is_preclear_candidate $theDisk; then
  echo -e "\n${bold}The disk '$theDisk' is part of unRAID's array, or is assigned as a cache device.${norm}"
  echo -e "\nPlease choose another one from below:\n"
  list_device_names
  echo -e "\n"
  debug "Disk $theDisk is part of unRAID array. Aborted."
  exit 1
fi

######################################################
##              VERIFY PRECLEAR STATUS              ##
######################################################

if [ "$verify_disk_mbr" == "y" ]; then
  max_steps=1
  if [ "$verify_zeroed" == "y" ]; then
    max_steps=2
  fi
  append display_title "${ul}unRAID Server: verifying Preclear State of '$theDisk${noul}' ."
  append display_title "Verifying disk '$theDisk' for unRAID's Preclear State."

  display_status "Verifying unRAID's signature on the MBR ..." ""
  echo "${disk_properties[name]}|NN|Verifying unRAID's signature on the MBR...|$$" > ${all_files[stat]}
  sleep 10
  if verify_mbr $theDisk; then
    append display_step "Verifying unRAID's Preclear MBR:|***SUCCESS***"
    echo "${disk_properties[name]}|NN|Verifying unRAID's signature on the MBR successful|$$" > ${all_files[stat]}
    display_status
  else
    append display_step "Verifying unRAID's signature:| ***FAIL***"
    echo "${disk_properties[name]}|NY|Verifying unRAID's signature on the MBR failed|$$" > ${all_files[stat]}
    display_status
    echo -e "--> RESULT: FAIL! $theDisk DOESN'T have a valid unRAID MBR signature!!!\n\n"
    if [ "$notify_channel" -gt 0 ]; then
      send_mail "FAIL! $theDisk DOESN'T have a valid unRAID MBR signature!!!" "$theDisk DOESN'T have a valid unRAID MBR signature!!!" "$theDisk DOESN'T have a valid unRAID MBR signature!!!" "" "alert"
    fi
    exit 1
  fi
  if [ "$max_steps" -eq "2" ]; then
    display_status "Verifying if disk is zeroed ..." ""
    if read_entire_disk verify zeroed average; then
      append display_step "Verifying if disk is zeroed:|${average} ***SUCCESS***"
      echo "${disk_properties[name]}|NN|Verifying if disk is zeroed: SUCCESS|$$" > ${all_files[stat]}
      display_status
      sleep 10
    else
      append display_step "Verifying if disk is zeroed:|***FAIL***"
      echo "${disk_properties[name]}|NY|Verifying if disk is zeroed: FAIL|$$" > ${all_files[stat]}
      display_status
      echo -e "--> RESULT: FAIL! $theDisk IS NOT zeroed!!!\n\n"
      if [ "$notify_channel" -gt 0 ]; then
        send_mail "FAIL! $theDisk IS NOT zeroed!!!" "FAIL! $theDisk IS NOT zeroed!!!" "FAIL! $theDisk IS NOT zeroed!!!" "" "alert"
      fi
      exit 1
    fi
  fi
  if [ "$notify_channel" -gt 0 ]; then
    send_mail "Disk $theDisk has been verified precleared!" "Disk $theDisk has been verified precleared!" "Disk $theDisk has been verified precleared!"
  fi
  echo "${disk_properties[name]}|NN|The disk is Precleared!|$$" > ${all_files[stat]}
  echo -e "--> RESULT: SUCCESS! Disk $theDisk has been verified precleared!\n\n"
  exit 0
fi

######################################################
##               WRITE PRECLEAR STATUS              ##
######################################################

# ask
append display_title "${ul}unRAID Server Pre-Clear of disk${noul} ${bold}$theDisk${norm}"

if [ "$no_prompt" != "y" ]; then
  ask_preclear
  tput clear
fi

if [ "$write_disk_mbr" == "y" ]; then
  write_signature 64
  exit 0
fi

######################################################
##                 PRECLEAR THE DISK                ##
######################################################

is_current_op() {
  if [ -n "$current_op" ] && [ "$current_op" == "$1" ]; then
    current_op=""
    return 0
  elif [ -z "$current_op" ]; then
    return 0
  else
    return 1
  fi
}

# reset timer
all_timer=$(( $(date '+%s') - $all_timer_diff ))

# Export initial SMART status
[ "$disable_smart" != "y" ] && save_smart_info $theDisk "$smart_type" "cycle_initial_start"

# Add current SMART status to display_smart
[ "$disable_smart" != "y" ] && compare_smart "cycle_initial_start"
[ "$disable_smart" != "y" ] && output_smart $theDisk "$smart_type"

if [ "$erase_disk" == "y" ]; then
  op_title="Erase"
  title_write="Erasing"
  write_op="erase"
else
  op_title="Preclear"
  title_write="Zeroing"
  write_op="zero"
fi

for cycle in $(seq $cycles); do
  # Continue to next cycle if restoring new-session
  if [ -n "$current_op" ] && [ "$cycle" != "$current_cycle" ]; then
    debug "skipping cycle ${cycle}."
    continue
  fi

  # Set a cycle timer
  cycle_timer=$(( $(date '+%s') - $cycle_timer_diff ))

  # Reset canvas
  unset display_title
  unset display_step && append display_step ""
  append display_title "${ul}unRAID Server ${op_title} of disk${noul} ${bold}${disk_properties['serial']}${norm}"

  if [ "$erase_disk" == "y" ]; then
    append display_title "Cycle ${bold}${cycle}$norm of ${cycles}."
  else
    append display_title "Cycle ${bold}${cycle}$norm of ${cycles}, partition start on sector 64."
  fi
  
  # Adjust the number of steps
  if [ "$erase_disk" == "y" ]; then
    max_steps=4

    # Disable pre-read and post-read if erasing
    skip_preread="y"
    skip_postread="y"
  else
    max_steps=6
  fi

  if [ "$skip_preread" == "y" ]; then
    let max_steps-=1
  fi
  if [ "$skip_postread" == "y" ]; then
    let max_steps-=1
  fi
  if [ "$erase_preclear" != "y" ]; then
    let max_steps-=1
  fi

  # Export initial SMART status
  [ "$disable_smart" != "y" ] && save_smart_info $theDisk "$smart_type" "cycle_${cycle}_start"

  # Do a preread if not skipped
  if [ "$skip_preread" != "y" ]; then

    # Check current operation if restoring a previous preclear instance
    if is_current_op "preread"; then

      # Loading restored position
      if [ -n "$current_pos" ]; then
        start_bytes=$current_pos
        start_timer=$current_timer
        current_pos=0
      else
        start_bytes=0
        current_timer=0
      fi

      # Updating display status 
      display_status "Pre-Read in progress ..." ''

      # Saving progress  
      save_current_status "preread" "$start_bytes" "$start_timer"

      while [[ true ]]; do
        read_entire_disk no-verify preread start_bytes start_timer preread_average preread_speed
        ret_val=$?
        if [ "$ret_val" -eq 0 ]; then
          append display_step "Pre-read verification:|[${preread_average}] ***SUCCESS***"
          display_status
          break
        elif [ "$ret_val" -eq 2 ]; then
          debug "dd process hung at ${start_bytes}, killing...."
          continue
        else
          append display_step "Pre-read verification:|${bold}FAIL${norm}"
          display_status
          echo "${disk_properties[name]}|NY|Pre-read verification failed - Aborted|$$" > ${all_files[stat]}
          send_mail "FAIL! Pre-read verification failed." "FAIL! Pre-read verification failed." "Pre-read verification failed - Aborted" "" "alert"
          echo -e "--> FAIL: Result: Pre-Read failed.\n\n"
          save_report "No - Pre-read verification failed." "$preread_speed" "$postread_speed" "$write_speed"
          rm "${all_files[resume_file]}"
          exit 1
        fi
      done
    else
      append display_step "Pre-read verification:|[${preread_average}] ***SUCCESS***"
      display_status
    fi
  fi

  # Erase the disk in erase-clear op
  if [ "$erase_preclear" == "y" ]; then

    # Check current operation if restoring a previous preclear instance
    if is_current_op "erase"; then

      # Loading restored position
      if [ -n "$current_pos" ]; then
        start_bytes=$current_pos
        start_timer=$current_timer
        current_pos=""
      else
        start_bytes=0
        start_timer=0
      fi

      display_status "Erasing in progress ..." ''
      save_current_status "erase" "$start_bytes" "$start_timer"

      # Erase the disk
      while [[ true ]]; do
        write_disk erase start_bytes start_timer write_average write_speed
        ret_val=$?
        if [ "$ret_val" -eq 0 ]; then
          append display_step "Erasing the disk:|[${write_average}] ***SUCCESS***"
          display_status
          break
        elif [ "$ret_val" -eq 2 ]; then
          debug "dd process hung at ${start_bytes}, killing...."
          continue
        else
          append display_step "Erasing the disk:|${bold}FAIL${norm}"
          display_status
          echo "${disk_properties[name]}|NY|Erasing the disk failed - Aborted|$$" > ${all_files[stat]}
          send_mail "FAIL! Erasing the disk failed." "FAIL! Erasing the disk failed." "Erasing the disk failed - Aborted" "" "alert"
          echo -e "--> FAIL: Result: Erasing the disk failed.\n\n"
          save_report "No - Erasing the disk failed." "$preread_speed" "$postread_speed" "$write_speed"
          rm "${all_files[resume_file]}"
          exit 1
        fi
      done
    else
      append display_step "Erasing the disk:|[${write_average}] ***SUCCESS***"
      display_status
    fi
  fi

  # Erase/Zero the disk
  # Check current operation if restoring a previous preclear instance
  if is_current_op "$write_op"; then
    
    # Loading restored position
    if [ -n "$current_pos" ]; then
      start_bytes=$current_pos
      start_timer=$current_timer
      current_pos=""
    else
      start_bytes=0
      start_timer=0
    fi

    display_status "${title_write} in progress ..." ''
    save_current_status "$write_op" "$start_bytes" "$start_timer"
    while [[ true ]]; do
      write_disk $write_op start_bytes start_timer write_average write_speed
      ret_val=$?
      if [ "$ret_val" -eq 0 ]; then
        append display_step "${title_write} the disk:|[${write_average}] ***SUCCESS***"
        break
      elif [ "$ret_val" -eq 2 ]; then
        debug "dd process hung at ${start_bytes}, killing...."
        continue
      else
        append display_step "${title_write} the disk:|${bold}FAIL${norm}"
        display_status
        echo "${disk_properties[name]}|NY|${title_write} the disk failed - Aborted|$$" > ${all_files[stat]}
        send_mail "FAIL! ${title_write} the disk failed." "FAIL! ${title_write} the disk failed." "${title_write} the disk failed - Aborted" "" "alert"
        echo -e "--> FAIL: Result: ${title_write} the disk failed.\n\n"
        save_report "No - ${title_write} the disk failed." "$preread_speed" "$postread_speed" "$write_speed"
        rm "${all_files[resume_file]}"
        exit 1
      fi
    done
  else
    append display_step "${title_write} the disk:|[${write_average}] ***SUCCESS***"
    display_status
  fi

  if [ "$erase_disk" != "y" ]; then

      # Write unRAID's preclear signature to the disk
      # Check current operation if restoring a previous preclear instance
      if is_current_op "write_mbr"; then

        display_status "Writing unRAID's Preclear signature to the disk ..." ''
        save_current_status "write_mbr" "0" "0"
        echo "${disk_properties[name]}|NN|Writing unRAID's Preclear signature|$$" > ${all_files[stat]}
        write_signature 64
        # sleep 10
        append display_step "Writing unRAID's Preclear signature:|***SUCCESS***"
        echo "${disk_properties[name]}|NN|Writing unRAID's Preclear signature finished|$$" > ${all_files[stat]}
        # sleep 10
      else
        append display_step "Writing unRAID's Preclear signature:|***SUCCESS***"
        display_status
      fi

      # Verify unRAID's preclear signature in disk
      # Check current operation if restoring a previous preclear instance
      if is_current_op "read_mbr"; then
        display_status "Verifying unRAID's signature on the MBR ..." ""
        save_current_status "read_mbr" "0" "0"
        echo "${disk_properties[name]}|NN|Verifying unRAID's signature on the MBR|$$" > ${all_files[stat]}
        if verify_mbr $theDisk; then
          append display_step "Verifying unRAID's Preclear signature:|***SUCCESS*** "
          display_status
          echo "${disk_properties[name]}|NN|unRAID's signature on the MBR is valid|$$" > ${all_files[stat]}
        else
          append display_step "Verifying unRAID's Preclear signature:|***FAIL*** "
          display_status
          echo -e "--> FAIL: unRAID's Preclear signature not valid. \n\n"
          echo "${disk_properties[name]}|NY|unRAID's signature on the MBR failed - Aborted|$$" > ${all_files[stat]}
          send_mail "FAIL! unRAID's signature on the MBR failed." "FAIL! unRAID's signature on the MBR failed." "unRAID's signature on the MBR failed - Aborted" "" "alert"
          save_report  "No - unRAID's Preclear signature not valid." "$preread_speed" "$postread_speed" "$write_speed"
          rm "${all_files[resume_file]}"
          exit 1
        fi
      else
        append display_step "Verifying unRAID's Preclear signature:|***SUCCESS*** "
        display_status
      fi

  fi

  # Do a post-read if not skipped
  if [ "$skip_postread" != "y" ]; then

    # Check current operation if restoring a previous preclear instance
    if is_current_op "postread"; then

      # Loading restored position
      if [ -n "$current_pos" ]; then
        start_bytes=$current_pos
        start_timer=$current_timer
        current_pos=""
      else
        start_bytes=0
        start_timer=0
      fi

      display_status "Post-Read in progress ..." ""
      save_current_status "postread" "$start_bytes" "$start_timer"
      while [[ true ]]; do
        read_entire_disk verify postread start_bytes start_timer postread_average postread_speed
        ret_val=$?
        if [ "$ret_val" -eq 0 ]; then
          append display_step "Post-Read verification:|[${postread_average}] ***SUCCESS*** "
          display_status
          echo "${disk_properties[name]}|NY|Post-Read verification successful|$$" > ${all_files[stat]}
          break
        elif [ "$ret_val" -eq 2 ]; then
          debug "dd process hung at ${start_bytes}, killing...."
          continue
        else
          append display_step "Post-Read verification:|***FAIL***"
          display_status
          echo -e "--> FAIL: Post-Read verification failed. Your drive is not zeroed.\n\n"
          echo "${disk_properties[name]}|NY|Post-Read verification failed - Aborted|$$" > ${all_files[stat]}
          send_mail "FAIL! Post-Read verification failed." "FAIL! Post-Read verification failed." "Post-Read verification failed - Aborted" "" "alert"
          save_report "No - Post-Read verification failed." "$preread_speed" "$postread_speed" "$write_speed"
          rm "${all_files[resume_file]}"
          exit 1
        fi
      done
    fi
  fi

  # Export final SMART status for cycle
  [ "$disable_smart" != "y" ] && save_smart_info $theDisk "$smart_type" "cycle_${cycle}_end"
  # Compare start/end values
  [ "$disable_smart" != "y" ] && compare_smart "cycle_${cycle}_start" "cycle_${cycle}_end" "CYCLE $cycle"
  # Add current SMART status to display_smart
  [ "$disable_smart" != "y" ] && output_smart $theDisk "$smart_type"
  display_status '' ''

  # Send end of the cycle notification
  if [ "$notify_channel" -gt 0 ] && [ "$notify_freq" -ge 2 ]; then
    report_out="Disk ${disk_properties[name]} has successfully finished a preclear cycle!\\n\\n"
    report_out+="Finished Cycle $cycle of $cycles cycles.\\n"
    [ "$skip_preread" != "y" ] && report_out+="Last Cycle's Pre-Read Time: ${preread_average}.\\n"
    if [ "$erase_disk" == "y" ]; then
      report_out+="Last Cycle's Erasing Time: ${write_average}.\\n"
    else
      report_out+="Last Cycle's Zeroing Time: ${write_average}.\\n"
    fi
    [ "$skip_postread" != "y" ] && report_out+="Last Cycle's Post-Read Time: ${postread_average}.\\n"
    report_out+="Last Cycle's Elapsed TIme: $(timer cycle_timer)\\n"
    report_out+="Disk Start Temperature: ${disk_properties[temp]}\n"
    report_out+="Disk Current Temperature: $(get_disk_temp $theDisk "$smart_type")\\n"
    [ "$cycles" -gt 1 ] && report_out+="\\nStarting a new cycle.\\n"
    send_mail "Disk ${disk_properties[name]} PASSED cycle ${cycle}!" "${op_title}: Disk ${disk_properties[name]} PASSED cycle ${cycle}!" "$report_out"
  fi
done

echo "${disk_properties[name]}|NN|${op_title} Finished Successfully!|$$" > ${all_files[stat]};

if [ "$disable_smart" != "y" ]; then
  echo -e "\n--> ATTENTION: Please take a look into the SMART report above for drive health issues.\n"
fi
echo -e "--> RESULT: ${op_title} Finished Successfully!.\n\n"

# # Saving report
report="${all_files[dir]}/report"

# Remove resume information
rm "${all_files[resume_file]}"

tmux_window="preclear_disk_${disk_properties[serial]}"
if [ "$(tmux ls 2>/dev/null | grep -c "${tmux_window}")" -gt 0 ]; then
  tmux capture-pane -t "${tmux_window}" && tmux show-buffer >$report 2>&1
else
  display_status '' '' >$report
  if [ "$disable_smart" != "y" ]; then
    echo -e "\n--> ATTENTION: Please take a look into the SMART report above for drive health issues.\n" >>$report
  fi
  echo -e "--> RESULT: ${op_title} Finished Successfully!.\n\n" >>$report
  report_tmux="preclear_disk_report_${disk_properties[name]}"

  tmux new-session -d -x 140 -y 200 -s "${report_tmux}"
  tmux send -t "${report_tmux}" "cat '$report'" ENTER
  sleep 1

  tmux capture-pane -t "${report_tmux}" && tmux show-buffer >$report 2>&1
  tmux kill-session -t "${report_tmux}" >/dev/null 2>&1
fi

# Remove empy lines
sed -i '/^$/{:a;N;s/\n$//;ta}' $report

# Save report to Flash disk
mkdir -p /boot/preclear_reports/
date_formated=$(date "+%Y.%m.%d_%H.%M.%S")
file_name=$(echo "preclear_report_${disk_properties[serial]}_${date_formated}.txt" | sed -e 's/[^A-Za-z0-9._-]/_/g')
todos < $report > "/boot/preclear_reports/${file_name}"

# Send end of the script notification
if [ "$notify_channel" -gt 0 ] && [ "$notify_freq" -ge 1 ]; then
  report_out="Disk ${disk_properties[name]} has successfully finished a preclear cycle!\\n\\n"
  report_out+="Ran $cycles cycles.\\n"
  [ "$skip_preread" != "y" ] && report_out+="Last Cycle's Pre-Read Time: ${preread_average}.\\n"
  if [ "$erase_disk" == "y" ]; then
    report_out+="Last Cycle's Erasing Time: ${write_average}.\\n"
  else
    report_out+="Last Cycle's Zeroing Time: ${write_average}.\\n"
  fi
  [ "$skip_postread" != "y" ] && report_out+="Last Cycle's Post-Read Time: ${postread_average}.\\n"
  report_out+="Last Cycle's Elapsed TIme: $(timer cycle_timer)\\n"
  report_out+="Disk Start Temperature: ${disk_properties[temp]}\n"
  report_out+="Disk Current Temperature: $(get_disk_temp $theDisk "$smart_type")\\n"
  if [ "$disable_smart" != "y" ]; then
    report_out+="\\n\\nS.M.A.R.T. Report\\n"
    while read -r line; do report_out+="${line}\\n"; done < ${all_files[smart_out]}
  fi
  report_out+="\\n\\n"
  send_mail "${op_title}: PASS! Preclearing Disk ${disk_properties[name]} Finished!!!" "${op_title}: PASS! Preclearing Disk ${disk_properties[name]} Finished!!! Cycle ${cycle} of ${cycles}" "${report_out}"
fi

# debug
debug "dd_out:\n $(cat ${all_files[dd_out]})"
debug "dd_out:\n $(cat ${all_files[cmp_out]})"

save_report "Yes" "$preread_speed" "$postread_speed" "$write_speed"

