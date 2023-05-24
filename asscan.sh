#!/bin/bash
# asscan 获取 CF 反代节点

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update -f")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")
n=0

for i in `echo ${linux_os[@]}`
do
	if [ $i == $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') ]
	then
		break
	else
		n=$[$n+1]
	fi
done

if [ $n == 5 ]
then
	echo "当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)没有适配"
	echo "默认使用APT包管理器"
	n=0
fi

if [ -z $(type -P curl) ]
then
	echo "缺少curl,正在安装..."
	${linux_update[$n]}
	${linux_install[$n]} curl
fi

if [ -z $(type -P masscan) ]
then
	echo "缺少masscan,正在安装..."
	${linux_update[$n]}
	${linux_install[$n]} masscan
fi


if [ $(cat /proc/net/dev | sed '1,2d' | awk -F: '{print $1}' | grep -w -v "lo" | sed -e 's/ //g' | wc -l) == 1 ]
then
	Interface=$(cat /proc/net/dev | sed '1,2d' | awk -F: '{print $1}' | grep -w -v "lo" | sed -e 's/ //g')
	echo "网口已经自动设置为 $Interface"
	sleep 3
else
	if [ ! -f "setting.txt" ]
	then
		echo "多网口模式下,首次使用需要设置默认网口"
		echo "如需更改默认网口,请删除setting.txt后重新运行脚本"
		echo "当前可用网口如下"
		cat /proc/net/dev | sed '1,2d' | awk -F: '{print $1}' | grep -w -v "lo" | sed -e 's/ //g'
		read -p "选择当前需要抓包的网卡: " Interface
		if [ -z "$Interface" ]
		then
			echo "请输入正确的网口名称"
			exit
		fi
		if [ $(cat /proc/net/dev | sed '1,2d' | awk -F: '{print $1}' | grep -w -v "lo" | sed -e 's/ //g' | grep -w "$Interface" | wc -l) == 0 ]
		then
			echo "找不到网口 $Interface"
			exit
		else
			echo $Interface>setting.txt
		fi
	else
		Interface=$(cat setting.txt)
		echo "网口已经自动设置为 $Interface"
		echo "如需更改默认网口,请删除setting.txt后重新运行脚本"
		sleep 3
	fi
fi

clear
chmod +x ip
ulimit -n 102400
echo "本脚需要用root权限执行masscan扫描"
echo "请自行确认当前是否以root权限运行"
echo "1.单个AS模式"
echo "2.批量AS列表模式"
read -p "请输入模式号(默认模式1):" scanmode
if [ -z "$scanmode" ]
then
	scanmode=1
fi
if [ $scanmode == 1 ]
then
	clear
	echo "当前为单个AS模式"
	read -p "请输入AS号码(默认45102):" asn
	read -p "请输入扫描端口(默认443):" port
	if [ -z "$asn" ]
	then
		asn=45102
	fi
	if [ -z "$port" ]
	then
		port=443
	fi
elif [ $scanmode == 2 ]
then
	clear
	echo "当前批量AS列表模式"
	echo "待扫描的默认列表文件as.txt格式如下所示"
	echo -e "\n45102:443\n132203:443\n自治域号:端口号\n"
	read -p "请设置列表文件(默认as.txt):" filename
	if [ -z "$filename" ]
	then
		filename=as.txt
	fi
else
	echo "输入的数值不正确,脚本已退出!"
	exit
fi
read -p "请设置masscan pps rate(默认10000):" rate
read -p "请设置iptest https测试协程数(默认500):" httptask
read -p "是否需要测速[(默认0.否)多线程测速1-10的数字]:" mode
read -p "是否开启tls，测试80端口请关闭tls，否则没有IP （默认0.否）1开启tls:" tls
if [ -z "$rate" ]
then
	rate=10000
fi
if [ -z "$httptask" ]
then
	httptask=500
fi
if [ -z "$mode" ]
then
	mode=0
fi

if [ "$tls" = "1" ]; then
  tls=true
else
  tls=false
fi

function colocation(){
curl --ipv4 --retry 3 -s https://speed.cloudflare.com/locations | sed -e 's/},{/\n/g' -e 's/\[{//g' -e 's/}]//g' -e 's/"//g' -e 's/,/:/g' | awk -F: '{print $12","$10"-("$2")"}'>colo.txt
}

function cloudflarerealip(){
rm -rf realip.txt allip.txt
grep tcp data.txt | awk '{print $4}' | tr -d '\r'>allip.txt
./ip -port=$port -max=$httptask -speedtest=$mode -file=allip.txt -outfile=$asn-$port.csv -tls=$tls
rm -rf allip.txt
}

function main(){
start=`date +%s`
echo "正在获取公网出口IP地址"
publicip=$(curl --ipv4 -s https://www.cloudflare-cn.com/cdn-cgi/trace | grep ip= | cut -f 2- -d'=')
echo "当前公网出口IP $publicip"
if [ ! -f "colo.txt" ]
then
	echo "生成colo.txt"
	colocation
else
	echo "colo.txt 已存在,跳过此步骤!"
fi
if [ ! -d asn ]
then
	mkdir asn
fi
if [ ! -f "asn/$asn" ]
then
	echo "正在从ipip.net上下载AS$asn数据"
	curl -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36' -s https://whois.ipip.net/AS$asn | grep /AS$asn/ | awk '{print $2}' | sed -e 's#"##g' | awk -F/ '{print $3"/"$4}' | grep -v :>asn/$asn
	echo "AS$asn数据下载完毕"
else
	echo "AS$asn 已存在,跳过数据下载!"
fi
echo "开始检测 AS$asn TCP端口 $port 有效性"
rm -rf paused.conf
masscan -p $port -iL asn/$asn --wait=3 --rate=$rate -oL data.txt --interface $Interface
echo "开始检测 AS$asn REAL IP有效性"
cloudflarerealip
end=`date +%s`
echo "AS$asn-$port 耗时:$[$end-$start]秒"
}

if [ $scanmode == 2 ]
then
	for i in `cat $filename`
	do
		asn=$(echo $i | awk -F: '{print $1}')
		port=$(echo $i | awk -F: '{print $2}')
		main
	done
else
	main
fi
