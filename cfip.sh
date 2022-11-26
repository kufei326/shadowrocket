 #!/bin/bash
# cloudflare officials colocation

asn=13335
port=80
read -p "请设置curl测试进程数(默认50,最大100):" tasknum
if [ -z "$tasknum" ]
then
	tasknum=50
fi
if [ $tasknum -eq 0 ]
then
	echo "进程数不能为0,自动设置为默认值"
	tasknum=50
fi
if [ $tasknum -gt 100 ]
then
	echo "超过最大进程限制,自动设置为最大值"
	tasknum=100
fi

function divsubnet(){
mask=$5;a=$1;b=$2;c=$3;d=$4;
echo "拆分子网:$a.$b.$c.$d/$mask";

if [ $mask -ge 8 ] && [ $mask -le 23 ];then
    ipstart=$(((a<<24)|(b<<16)|(c<<8)|l));
    hostend=$((2**(32-mask)-1));
    loop=0;
    while [ $loop -le $hostend ]
    do
        subnet=$((ipstart|loop));
        a=$(((subnet>>24)&255));
        b=$(((subnet>>16)&255));
        c=$(((subnet>>8)&255));
        d=$(((subnet>>0)&255));
        loop=$((loop+256));
        echo $a.$b.$c.$d/24 >> ips.txt;
    done
else
    echo $a.$b.$c.$d/24 >> ips.txt;
fi
}

function getip(){
rm -rf ips.txt
for i in `cat $asn`
do
	a=$(echo $i | awk -F. '{print $1}');
	b=$(echo $i | awk -F. '{print $2}');
	c=$(echo $i | awk -F. '{print $3}');
	d=$(echo $i | awk -F. '{print $4}' | awk -F/ '{print $1}');
	mask=$(echo $i | awk -F/ '{print $2}');
	divsubnet $a $b $c $d $mask
done
sort -u ips.txt | sed -e 's/\./#/g' | sort -t# -k 1n -k 2n -k 3n -k 4n | sed -e 's/#/\./g'>$asn-24
rm -rf ips.txt
}

function colocation(){
curl --ipv4 --retry 3 -s https://speed.cloudflare.com/locations | sed -e 's/},{/\n/g' -e 's/\[{//g' -e 's/}]//g' -e 's/"//g' -e 's/,/:/g' | awk -F: '{print $12","$10"-("$2")"}'>colo.txt
}

function rtt(){
if [ $(echo $1 | grep : | wc -l) == 1 ]
then
	ip=$(echo $1 | awk -F: '{print $1":"$2":"$3}'):$(printf '%x\n' $(($RANDOM*2+$RANDOM%2))):$(printf '%x\n' $(($RANDOM*2+$RANDOM%2))):$(printf '%x\n' $(($RANDOM*2+$RANDOM%2))):$(printf '%x\n' $(($RANDOM*2+$RANDOM%2))):$(printf '%x\n' $(($RANDOM*2+$RANDOM%2)))
else
	ip=$(echo $1 | awk -F\. '{print $1"."$2"."$3}').$(($RANDOM%256))
fi
n=0
for i in `curl -A "trace" http://$ip:$2/cdn-cgi/trace -s --connect-timeout 2 --max-time 3 -w "timems="%{time_connect}"\n"`
do
	temp[$n]=$i
	n=$[$n+1]
done
status=$(echo ${temp[@]} | sed -e 's/ /\n/g' | grep uag=trace | wc -l)
if [ $status == 1 ]
then
	clientip=$(echo ${temp[@]} | sed -e 's/ /\n/g' | grep ip= | cut -f 2- -d'=')
	colo=$(echo ${temp[@]} | sed -e 's/ /\n/g' | grep colo= | cut -f 2- -d'=')
	location=$(grep $colo colo.txt | awk -F"-" '{print $1}' | awk -F"," '{print $1}')
	ms=$(echo ${temp[@]} | sed -e 's/ /\n/g' | grep timems= | awk -F"=" '{printf ("%d\n",$2*1000)}')
	if [[ "$clientip" == "$publicip" ]]
	then
		ipstatus=官方
	elif [[ "$clientip" == "$ip" ]]
	then
		ipstatus=中转
	else
		ipstatus=隧道
	fi
	echo "$1,$location,$colo,$ipstatus,$ms ms" >> rtt.txt
fi
unset temp
}

function cloudflarertt(){
rm -rf rtt.txt
declare -i ipnum
declare -i seqnum
declare -i n=1
ipnum=$(cat $asn-24 | tr -d '\r' | wc -l)
seqnum=$tasknum
if [ $ipnum == 0 ]
then
	echo "当前没有任何IP"
fi
if [ $tasknum == 0 ]
then
	tasknum=1
fi
if [ $ipnum -lt $tasknum ]
then
	seqnum=$ipnum
fi
trap "exec 6>&-; exec 6<&-;exit 0" 2
tmp_fifofile="./$$.fifo"
mkfifo $tmp_fifofile &> /dev/null
exec 6<>$tmp_fifofile
rm -f $tmp_fifofile
for i in `seq $seqnum`;
do
	echo >&6
done
n=1
for i in `cat $asn-24 | tr -d '\r'`
do
		read -u6;
		{
		rtt $i $port;
		echo >&6
		}&
		echo "IP总数 $ipnum 已完成 $n"
		n=n+1
done
wait
exec 6>&-
exec 6<&-
echo "IP全部测试完成"
}

function main(){
start=`date +%s`
publicip=$(curl --ipv4 -s https://www.cloudflare-cn.com/cdn-cgi/trace | grep ip= | cut -f 2- -d'=')
if [ ! -f "colo.txt" ]
then
	echo "生成colo.txt"
	colocation
else
	echo "colo.txt 已存在,跳过此步骤!"
fi
if [ ! -f "$asn" ]
then
	curl -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/102.0.5005.62 Safari/537.36' -s https://whois.ipip.net/AS$asn | grep /AS$asn/ | awk '{print $2}' | sed -e 's#"##g' | awk -F/ '{print $3"/"$4}' | grep -v :>$asn
	echo "$asn数据下载完毕"
else
	echo "$asn 已存在,跳过数据下载!"
fi
if [ ! -f "$asn-24" ]
then
	getip
else
	echo $asn-24 "已存在,跳过CIDR拆分!"
fi
echo "开始检测 AS$asn RTT信息"
cloudflarertt
if [ ! -f "rtt.txt" ]
then
	rm -rf data.txt realip.txt rtt.txt
	echo "当前没有任何有效IP"
else
	echo "IP,地区,数据中心,IP类型,网络延迟">AS$asn.csv
	cat rtt.txt | sort >>AS$asn.csv
	rm -rf data.txt realip.txt rtt.txt
	echo "AS$asn.csv 已经生成"
fi
end=`date +%s`
echo "AS$asn 耗时:$[$end-$start]秒"
}

main
