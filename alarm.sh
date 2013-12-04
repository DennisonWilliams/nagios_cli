#!/bin/bash

if [ ! -f $1 ]; then
	echo You must specify a file to play as an argument
	exit
fi

playsound() {
	/usr/bin/mpg123 -q --loop \-1 $1
}

for x in `amixer controls  | grep layback.*witch | awk -F, '{print $1}'` ; do 
	amixer cset "${x}" on 2>&1 > /dev/null
done
# This is broken :(
#amixer cset Master unmute 2>&1 > /dev/null

playsound $1 &

# start with the volume low and slowly increase it to max
max=64
mul=10
ct=1
while [ $(($ct*$mul)) -lt $max ]; do
	amixer -c 0 cset numid=25 $(($ct*$mul)) 2>&1 > /dev/null
	ct=$(($ct+1))
	sleep 30
done

