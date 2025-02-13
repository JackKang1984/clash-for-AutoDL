#!/bin/bash

set +m  # 关闭监视模式，不再报告后台作业状态

Status=0  # 脚本运行状态，默认为0，表示成功

#################### 脚本初始化任务 ####################
# 杀死clash相关的所有进程
pids=$(pgrep -f "clash-linux")
if [ -n "$pids" ]; then
    kill $pids &>/dev/null
fi

# 获取脚本工作目录绝对路径
export Server_Dir="$( cd "$( dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd )"

# 加载.env变量文件
source $Server_Dir/.env

# 给二进制启动程序、脚本等添加可执行权限
chmod +x $Server_Dir/bin/*

# 定义日志文件路径
log_file="logs/clash.log"

#################### 变量设置 ####################
Conf_Dir="$Server_Dir/conf"
Log_Dir="$Server_Dir/logs"

# 将 CLASH_URL 变量的值赋给 URL 变量，并检查 CLASH_URL 是否为空
URL=${CLASH_URL:?Error: CLASH_URL variable is not set or empty}

# 获取 CLASH_SECRET 值，如果不存在则生成一个随机数
Secret=${CLASH_SECRET:-$(openssl rand -hex 32)}

# 订阅文件默认名 
Config_File="$Conf_Dir/config.yaml"

#################### 函数定义 ####################

# 自定义action函数，实现通用action功能
success() {
    echo -en "\033[60G[\033[1;32m  OK  \033[0;39m]\r"
    return 0
}

failure() {
    local rc=$?
    echo -en "\033[60G[\033[1;31mFAILED\033[0;39m]\r"
    [ -x /bin/plymouth ] && /bin/plymouth --details
    return $rc
}

action() {
    local STRING rc

    STRING=$1
    echo -n "$STRING "
    shift
    "$@" && success $"$STRING" || failure $"$STRING"
    rc=$?
    echo
    return $rc
}

# 判断命令是否正常执行的函数
if_success() {
    local ReturnStatus=${3:-0}  # 如果 \$3 未设置或为空，则默认为 0
    if [ "$ReturnStatus" -eq 0 ]; then
        action "$1" /bin/true
        Status=0  # 脚本运行状态设置为0，表示成功
    else
        action "$2" /bin/false
        Status=1  # 脚本运行状态设置为1，表示失败
    fi
}

# 检查并更新配置
update_config() {
    local key="$1"
    local value="$2"

    # 检查配置项是否已存在
    if grep -q "^${key}:" "$Config_File"; then
        # 配置项存在，更新它
        sed -ri "s@^${key}:.*@${key}: ${value}@g" "$Config_File"
    else
        # 配置项不存在，添加它
        echo "${key}: ${value}" >> "$Config_File"
    fi
}

# 函数：安全删除文件
safe_remove() {
    local file="$1"
    if [ -f "$file" ]; then
        rm "$file"
        echo "已删除文件: $file"
    else
        echo "文件不存在，跳过删除: $file"
    fi
}

#################### 鲁棒设置 ####################

# 删除日志
rm -rf "$Log_Dir"

# 定义要删除的函数名
functions_to_remove=("proxy_on" "proxy_off" "shutdown_system")

# 遍历函数名数组
for func in "${functions_to_remove[@]}"; do
    # 使用sed命令删除函数定义及其结束
    sed -i -E "/^function[[:space:]]+${func}[[:space:]]*()/,/^}$/d" ~/.bashrc
done

sed -i "/^# 开启系统代理/d" ~/.bashrc
sed -i "/^# 关闭系统代理/d" ~/.bashrc
sed -i "/^# 新增关闭系统函数/d" ~/.bashrc
sed -i "/^# 检查clash进程是否正常启动/d" ~/.bashrc

# 删除自动执行 proxy_on 命令的行
sed -i "/proxy_on/d" ~/.bashrc

# 可能还需要删除与proxy_on相关的注释或空行，确保没有遗漏
sed -i "/^#.*proxy_on/d" ~/.bashrc  # 删除所有含 proxy_on 的注释行
sed -i '/^$/N;/^\n$/D' ~/.bashrc    # 删除连续的空行

#################### 任务执行 ####################
## 获取CPU架构
if /bin/arch &>/dev/null; then
    CpuArch=`/bin/arch`
elif /usr/bin/arch &>/dev/null; then
    CpuArch=`/usr/bin/arch`
elif /bin/uname -m &>/dev/null; then
    CpuArch=`/bin/uname -m`
else
    echo -e "\033[31m\n[ERROR] Failed to obtain CPU architecture！\033[0m"
fi

# Check if we obtained CPU architecture, and Status is still 0
if [[ $Status -eq 0 ]]; then
  if [[ -z "$CpuArch" ]] ; then
        echo "Failed to obtain CPU architecture"
        Status=1  # 脚本运行状态设置为1，表示失败
  fi
fi 

## 临时取消环境变量
unset http_proxy
unset https_proxy
unset no_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset NO_PROXY

#################### 设置config.yaml ####################

if [[ $Status -eq 0 ]]; then
    # 检查是否存在配置文件
    if [ -f "$Config_File" ]; then
        echo "配置文件已存在，无需下载。"
    else
        # 检查URL是否有效
        echo -e '\n正在检测订阅地址...'
        Text1="Clash订阅地址可访问！"
        Text2="Clash订阅地址不可访问！"
        curl -o /dev/null -L -k -sS --retry 5 -m 10 --connect-timeout 10 -w "%{http_code}" $URL | grep -E '^[23][0-9]{2}$' &>/dev/null
        ReturnStatus=$?
        if_success $Text1 $Text2 $ReturnStatus

        if [[ $Status -eq 0 ]]; then
            # 下载配置文件
            echo -e '\n正在下载Clash配置文件...'
            Text3="配置文件config.yaml下载成功！"
            Text4="配置文件config.yaml下载失败，退出启动！"
            curl -L -k -sS --retry 5 -m 10 -o $Config_File $URL
            ReturnStatus=$?
            if [ $ReturnStatus -ne 0 ]; then
                # 如果使用curl下载失败，尝试使用wget进行下载
                for i in {1..10}
                do
                    wget -q --no-check-certificate -O $Config_File $URL
                    ReturnStatus=$?
                    if [ $ReturnStatus -eq 0 ]; then
                        break
                    else
                        continue
                    fi
                done
            fi
            if_success $Text3 $Text4 $ReturnStatus

            # 更新配置项
            update_config "external-ui" "${Server_Dir}/dashboard/public"
            update_config "secret" "$Secret"
            update_config "port" "7890"
            update_config "socks-port" "7891"
            update_config "redir-port" "7892"
            update_config "allow-lan" "true"
            update_config "mode" "rule"
            update_config "log-level" "silent"
            update_config "external-controller" "'127.0.0.1:6006'"
        fi
    fi
fi

####################  检查logs目录是否存在,不存在则创建 ####################
if [ ! -d "$Log_Dir" ]; then
    mkdir -p "$Log_Dir"
    if [ $? -eq 0 ]; then
        echo "成功创建logs目录: $Log_Dir"
    else
        echo "创建logs目录失败,请检查权限"
        exit 1
    fi
fi

#################### 启动clash ####################
if [[ $Status -eq 0 ]]; then
    ## 启动Clash服务
    echo -e '\n正在启动Clash服务...'
    Text5="服务启动成功！"
    Text6="服务启动失败！"
    if [[ $CpuArch =~ "x86_64" || $CpuArch =~ "amd64"  ]]; then
        nohup $Server_Dir/bin/clash-linux-amd64 -d $Conf_Dir &> $Log_Dir/clash.log &
        ReturnStatus=$?
        if_success $Text5 $Text6 $ReturnStatus
    elif [[ $CpuArch =~ "aarch64" ||  $CpuArch =~ "arm64" ]]; then
        nohup $Server_Dir/bin/clash-linux-arm64 -d $Conf_Dir &> $Log_Dir/clash.log &
        ReturnStatus=$?
        if_success $Text5 $Text6 $ReturnStatus
    elif [[ $CpuArch =~ "armv7" ]]; then
        nohup $Server_Dir/bin/clash-linux-armv7 -d $Conf_Dir &> $Log_Dir/clash.log &
        ReturnStatus=$?
        if_success $Text5 $Text6 $ReturnStatus
    else
        echo -e "\033[31m\n[ERROR] Unsupported CPU Architecture！\033[0m"
        exit 0
    fi
fi

if [[ $Status -eq 0 ]]; then
    # Output Dashboard access address and Secret
    echo ''
    echo -e "Clash Dashboard 访问地址: http://<ip>:6006/ui"
    echo -e "Secret: ${Secret}"
    echo ''
fi

if [[ $Status -eq 0 ]]; then
    # 定义要添加的内容
    content_to_add=$(printf '

# 开启系统代理
function proxy_on() {
    export http_proxy=http://127.0.0.1:7890
    export https_proxy=http://127.0.0.1:7890
    export no_proxy=127.0.0.1,localhost
    export HTTP_PROXY=http://127.0.0.1:7890
    export HTTPS_PROXY=http://127.0.0.1:7890
    export NO_PROXY=127.0.0.1,localhost

    # 检查logs目录是否存在,不存在则创建
    if [ ! -d "%s/logs" ]; then
        mkdir "%s/logs"
        if [ $? -eq 0 ]; then
            %s/restart.sh
            sleep 5
            if ! pgrep -f "clash-linux" > /dev/null; then
                echo -e "\033[31m[×] 尝试重启后，clash 进程未能启动。代理启动失败\033[0m"
                exit 1
            fi
        else
            echo "创建logs目录失败,请检查权限"
            return            
        fi
    fi

    # 再次检测是否有clash进程存在
    pids=$(pgrep -f "clash-linux")
    if [ -n "$pids" ]; then
        echo -e "\033[32m[√] clash 进程已成功启动\033[0m"
        echo -e "\033[32m[√] 已开启代理\033[0m"
        return
    fi

    # 启动 restart.sh 脚本
    %s/restart.sh
    
    pids=$(pgrep -f "clash-linux")
    if [ -n "$pids" ]; then
        echo -e "\033[32m[√] clash 进程已成功启动\033[0m"
        echo -e "\033[32m[√] 已开启代理\033[0m"
        return
    else
        echo -e "\033[31m[×] 尝试重启后，clash 进程未能启动。代理启动失败\033[0m"
    fi
}

# 关闭系统代理
function proxy_off(){
    unset http_proxy
    unset https_proxy
    unset no_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset NO_PROXY
    echo -e "\033[31m[×] 已关闭代理\033[0m"
}

# 新增关闭系统函数
function shutdown_system() {
    echo "准备执行系统关闭脚本..."
    %s/shutdown.sh
}

proxy_on
' "$Server_Dir" "$Server_Dir" "$Server_Dir" "$Server_Dir" "$Server_Dir")

    # 检查 .bashrc 是否已包含 proxy_on 和 proxy_off 函数
    if ! grep -q 'function proxy_on()' ~/.bashrc || ! grep -q 'function proxy_off()' ~/.bashrc; then
        echo "$content_to_add" >> ~/.bashrc
        echo "已添加代理函数到 .bashrc，并设置为自动执行。\n"
    else
        echo "代理函数已存在于 .bashrc 中，无需重复添加\n"
    fi

    echo -e "请执行以下命令启动系统代理: proxy_on\n"
    echo -e "若要临时关闭系统代理，请执行: proxy_off\n"
    echo -e "若需要彻底删除，请调用: shutdown_system\n"
fi

####################  重新加载.bashrc文件以应用更改 ####################
if [[ $Status -eq 0 ]]; then
    source ~/.bashrc
fi

set -m # 恢复监视模式