#!/usr/bin/env bash
#
# coding: utf-8
#
# Program for showing the hierarchy of specific processes on a Unix computer.
# Like pstree but with searching for specific processes with pgrep first and display
# hierarchy of matching processes (parents and children)
# should work on any Unix supporting commands :
# pgrep
# ps (ax|-e) -o pid=,ppid=,user=,comm=|ucomm=,stime=|start=,args=
# (RedHat/CentOS/Fedora/Ubuntu/Suse/Solaris...)
#

# __author__ = "Franck Jouvanceau"
# __copyright__ = "Copyright 2026, Franck Jouvanceau"
# __license__ = "MIT"

usage() {
    cat - <<'EOF'
    usage: pgtree [-W] [-RIya] [-C <when>] [-O <psfield>] [-c|-k|-K] [-1|-p <pid1>,...|<pgrep args>]

    -I : use -o uid instead of -o user for ps command
         (if uid/user mapping is broken ps command can be stuck)
    -c : display processes and children only
    -k : kill -TERM processes and children
    -K : kill -KILL processes and children
    -y : do not ask for confirmation to kill
    -R : force use of internal pgrep
    -C : color preference : y/yes/always or n/no/never (default auto)
    -w : tty wrap text : y/yes or n/no (default y)
    -W : watch and follow process tree every 2s
    -a : use ascii characters
    -T : display threads (ps must support -T option)
    -O <psfield>[,psfield,...] : display multiple <psfield> instead of 'stime' in output
                   <psfield> must be valid with ps -o <psfield> command

    by default display full process hierarchy (parents + children of selected processes)

    -p <pids> : select processes pids to display hierarchy (default 0)
    -1 : display hierachy children of pid 1 (not including pid 0)
    <pgrep args> : use pgrep to select processes (see pgrep -h)

    found pids are prefixed with ►
EOF
    exit 1
}

PGT_PGREP=$(type -p pgrep)
[ "$PGT_PGREP" ] || PGT_PGREP='_pgrep'
ps -p $$ -o ucomm >/dev/null 2>&1 && fcomm=ucomm
[ ! "$fcomm" ] && ps -p $$ -o comm >/dev/null 2>&1 && fcomm=comm
[ "$fcomm" ] && {
    ps -p $$ -o stime >/dev/null 2>&1 && fstime=stime
    [ ! "$fstime" ] && ps -p $$ -o start >/dev/null 2>&1 && fstime=start
    [ ! "$fstime" ] && fstime=time
}
# busybox no -p option
[ ! "$fcomm" ] && ! ps -p $$ >/dev/null 2>&1 && fcomm=comm && fstime=time

SYSTEM=$(uname -s 2>/dev/null || echo "Linux")
PS_OPTION=(ax)
case "$SYSTEM" in
    AIX)    PS_OPTION=(-e); fstime="start" ;;
    Darwin) fstime="start" ;;
    SunOS)  PS_OPTION=(-e); fcomm="fname" ;;
esac

treedisplay () {
    # Tree display attributes
    [ "$use_ascii" ] && {
        selected=">"
        child="|_"
        notchild="| "
        lastchild="\\_"
    } || {
        selected="►"
        child="├─"
        notchild="│ "
        lastchild="└─"
    }
    [ "$use_color" ] && {
        COLOR_FG="\e[38;5;"
        COLOR_RESET="\e[0m"
        colors["pid"]="12m"
        colors["user"]="11m"
        colors["uid"]="11m"
        colors["comm"]="10m"
        colors["ucomm"]="10m"
        colors["fname"]="10m"
        colors["stime"]="14m"
        colors["start"]="14m"
        colors["time"]="14m"
        colors["args"]="15m"
        colors["default"]="13m"
    }
}

colorize() {
    local field="$1" value="$2"
    [ ! "${colors[$field]}" ] && printf "$COLOR_FG${colors["default"]}%s " "$value" || \
    printf "$COLOR_FG${colors[$field]}%s$COLOR_RESET " "$value"
}

proctree() {
    # Manage process tree of pids
    local i
    for i in "${pids[@]}"; do
        all_pids[$i]=$i
    done
    treedisplay
    get_psinfo
    build_tree
}

split_pinfo() {
    local line="$1" c=0 i pi
    for ((i=0; i<${#fields[@]}; i++)) ;do
        [ "${widths[i]}" ] && pi="${line:$c:${widths[i]}}" || pi="${line:$c}"
        pi="${pi#"${pi%%[![:space:]]*}"}"  # leading
        pi="${pi%"${pi##*[![:space:]]}"}"  # trailing
        pinfo[${fields[i]}]="$pi"
        ((c+= ${widths[i]} + 1))
    done
}

get_psinfo() {
    # parse unix ps command
    local i j fmt skip_header
    fields=( $fpid ppid $fuser $fcomm)
    widths=(30 30 30 30)
    [ "$xfields" ] || xfields=( $fstime )
    for i in "${xfields[@]}";do widths+=(50);fields+=( "$i" ); done
    fields+=( args )
    for ((i=0; i<${#fields[@]}; i++));do
        fmt=''
        [ "${widths[i]}" ] && {
            printf -v fmt '%*s' "${widths[i]}" ''
            fmt="=${fmt// /-}"
        }
        PS_OPTION+=( -o "${fields[i]}$fmt" )
    done
    ps_out=$(ps "${PS_OPTION[@]}")
    fields[0]="pid"
    for i in "${fields[@]}";do 
        ps_info["0,$i"]=" $i "
    done
    ps_info["0,pid"]=0
    ps_info["0,ppid"]=4294967297 # 2^32 + 1
    set_children 4294967297 0
    while IFS= read -r line;do
        [ ! "$skip_header" ] && skip_header=1 && continue
        split_pinfo "$line"
        pid=${pinfo["pid"]}
        [ "${pinfo["ppid"]}" = "$pid" ] && pinfo["ppid"]="4294967297"
        ppid=${pinfo["ppid"]}
        [[ $pid = $$ || $ppid = $$ ]] && continue
        set_children $ppid $pid
        pinfo[${fields[2]}]="(${pinfo[${fields[2]}]})"
        pinfo[${fields[3]}]="[${pinfo[${fields[3]}]#*/}]"
        for j in "${fields[@]}";do
            ps_info["$pid,$j"]="${pinfo[$j]}"
        done
    done <<<"$ps_out"
}

get_parents() {
    # get parents list of pids
    local pid ppid last_ppid
    for pid in "${all_pids[@]}";do
        [ "${ps_info["$pid,ppid"]}" ] || continue
        while [ "${ps_info["$pid,ppid"]}" ] ;do        
            ppid=${ps_info["$pid,ppid"]}
            set_pids_tree $ppid $pid
            last_ppid=$pid
            pid=$ppid
        done
        top_parents[$last_ppid]="$last_ppid"
    done
}
set_pids_tree() {
    local i
    for i in $2;do
        eval pids_tree_$1'[$i]=$i'
    done
}
is_pids_tree() {
    eval '((${#pids_tree_'$1'[@]}))'
}

set_children() {
    local i
    for i in $2;do
        eval children_$1'[$i]=$i'
    done
}

is_children() {
    eval '((${#children_'$1'[@]}))'
}

# recursive
children2tree() {
# build children tree
    local pids="$1" pid ch
    for pid in $pids;do
        is_pids_tree $pid && continue
        is_children $pid && {
            eval ch='${children_'$pid'[*]}'
            set_pids_tree $pid "$ch"
            children2tree "$ch"
        }
    done
}

build_tree() {
    #build process tree
    s_pids="${pids[*]}"
    children2tree "$s_pids"
    get_parents
}

print_proc() {
    # display process information with indent/tree/colors
    local pid="$1" pre="$2" print_it="$3" ppre i
    next_print_it="$3"
    ppre="$pre"
    [ "${all_pids[$pid]}" ] && {
        next_print_it=1
        ppre="$selected${pre:1}" #substr(pre, 2) # ⇒ 🠖 🡆 ➤ ➥ ► ▶
    }
    [ "$next_print_it" = 1 ] && {
        selected_pids+=($pid)
        if [ "$pre" = ' ' ] ;then  # head of hierarchy
            curr_p=' '
            next_p=' '
        elif [ "$last" ] ;then  # last child
            curr_p="$lastchild"
            next_p="  "
        else # not last child
            curr_p="$child"
            next_p="$notchild"
        fi
        printf "%s%s" "$ppre" "$curr_p"
        for i in "${fields[@]}";do
            [ "$i" = "ppid" ] && continue
            colorize "$i" "${ps_info["$pid,$i"]}"
        done
        printf "\n"
    }
}

# recursive
_print_tree(){
    # display wonderful process tree
    local pids="$1" print_it="$2" pre="$3" pid next_print_it next_p last pt last_pid
    last_pid="${pids##* }"
    for pid in $pids;do
        [ "$pid" = "$last_pid" ] && last=1
        print_proc "$pid" "$pre" "$print_it" "$last"
        eval pt='${'pids_tree_$pid'[@]}'
        _print_tree "$pt" "$next_print_it" "$pre$next_p"
    done
}

print_tree() {
    # display full or children only process tree
    [ "$sig" ] && kill_with_children "$sig" "$confirmed"  || \
        _print_tree "${top_parents[*]}" "$show_parents" " "
}

kill_with_children() {
    # kill processes and children with signal
    local killpids
    _print_tree "${top_parents[*]}" "0" " "
    [ "$selected_pids" ] || return 0
    for ((i=${#selected_pids[@]}-1;i>=0;i--));do
        killpids+=("${selected_pids[i]}")
    done
    printf "kill ${killpids[*]}\n"
    [ "$confirmed" ] || {
        read -p "Confirm (y/[n]) ? " answer
        [ "$answer" = "y" ] || return 0
    }
    kill -"$sig" "${killpids[@]}"
    return 0
}

main() {
    selected_pids=() all_pids=() top_parents=()
    declare -A pinfo=() ps_info=() colors=()
    proctree
    print_tree
}

pgt() {
    main
}


_pgrep() {
    local opts=fxiwu: psfield="$fcomm" icase exact=false

    while getopts "$opts" opt; do
        case $opt in
            f) psfield='args' ;;
            u) PS_OPTION=(-u "$OPTARG") ;;
            i) icase=1 ;;
            x) exact=true ;;
        esac
    done
    shift $((OPTIND - 1))
    re="$1"
    [ "$re" ] || re='.*'
    $exact && re="^$1$" || re="$1"
    printf -v w "%*s" 20 ''
    w=${w// /-}
    PS_OPTION+=( -o "$fpid=$w" -o "$psfield")
    ps "${PS_OPTION[@]}" | while IFS= read -r line;do
        pid=${line:0:19};pid=${pid// /}
        info=${line:21};info=${info//% /}
        [[ $info =~ $re ]] && echo "$pid"
    done
}

argopt="WRrThIckKfxvinoyaA1C:p:u:U:g:G:P:s:t:F:O:w:"
args=("$@")
pids=(0)
fpid='pid'
fuser='user'
pgrep_args=()
options=()
watch='false'
color='auto'
wrap='auto'
show_parents=1
sig=
while getopts "$argopt" opt; do
    case $opt in
        h) usage;;
        I) fuser='uid' ;;
        C) color="$OPTARG" ;;
        a) use_ascii=1;;
        c) show_parents=0;;
        y) confirmed=1;;
        W) watch=true ;;
        w) wrap="$OPTARG" ;;
        T) fpid='spid'; PS_OPTION+=(-T) ;;
        k) sig=15 ;;
        K) sig=9 ;;
        p) pids=( "$OPTARG" );popt=1 ;;
        O) eval 'xfields=('${OPTARG//,/ }')' ;;
        1) pids=(1) ;;
        R) PGT_PGREP='_pgrep' ;;
        [fxvinoA]) pgrep_args+=("-$opt") ;;
        [uUgGPstFOr]) pgrep_args+=("-$opt" "$OPTARG") ;;
        *) pgrep_args+=("$opt") ;;
    esac
done
shift $((OPTIND - 1)); unset OPTIND
pgrep_args+=("$@")
case "$color" in
    y|yes|always) use_color=1;;
    n|no|never) use_color="" ;;
    *) [ -t 1 ] && use_color=1 ;;
esac
case "$wrap" in
    y|yes) dowrap=true ;;
    n|no) dowrap=false ;;
    *) [ -t 1 ] && dowrap=true || dowrap=false ;;
esac
if [ "$fpid" = 'spid' ] ;then
    if [ "$popt" ];then
        pids=( $(ps -T -p "${pids[@]}" -o spid=) )
    else
        [ "$pgrep_args" ] && pids=( $($PGT_PGREP -w "${pgrep_args[@]}") )
    fi
else
    [ "$pgrep_args" ] && pids=( $($PGT_PGREP "${pgrep_args[@]}") )
fi
$dowrap && printf "\x1b[?7l"  # rmam
$watch && for ((i=0;i<${#args[@]};i++)); do
    [ "${args[i]}" = -W ] && unset "args[$i]" 
    [[ ${args[i]} = -*W* ]] && args[$i]=${args[i]//W/}
done
while $watch; do
    clear
    echo "Every 2.0s: pgtree ${args[*]}    $(date)"
    $0 "${args[@]}"
    sleep 2
done
pgt
$dowrap && printf "\x1b[?7h"  # smam
