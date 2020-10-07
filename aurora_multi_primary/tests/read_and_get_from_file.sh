#! /bin/bash 
#

FILETOPARSE=$1
LOCPATH=$2
STARTDELIMITER=$3
STOPDELIMITER=$4
WRITE=0
FILEOUTNAME=$(echo $FILETOPARSE |awk -F'.' '{print $1}')
FILEOUTNAME="${FILEOUTNAME}"
NUMBEROFLINES=0
SPLIT=0

	if [ "X${LOCPATH}" = "X" ] 
	then
		LOCPATH=`pwd`;
	fi 

	if [ -f "${LOCPATH}/${FILETOPARSE}" ] 
	then 
			echo "File ${LOCPATH}/${FILETOPARSE} OK";  
      echo ".. Calculating the number of line to process:";
      NUMBEROFLINES=$(wc -l ${LOCPATH}/${FILETOPARSE} |awk -F' ' '{print $1}')
      ORIGFILEOUTNAME=${LOCPATH}/$FILEOUTNAME
		else 
			echo " File ${LOCPATH}/${FILETOPARSE} does not exists";
			exit 1;
	fi


ask_confirmation(){
  echo "============================================="
  echo "FILE To Parse ${FILETOPARSE}"
  echo "Number of lines ${NUMBEROFLINES}"
  echo "Local Path  ${LOCPATH}"
  echo "Resulting file ${FILEOUTNAME}"
  echo "Start delimiter text  ${STARTDELIMITER}"
  echo "End delimiter text  ${STOPDELIMITER}"
  echo "============================================="

  read -p "Should continue? [y/n] " -n 1 -r
  echo    # (optional) move to a new line
  if [[ $REPLY =~ ^[Yy]$ ]]
  then
      echo "OK .. ";
    else
      echo "Stop processing."
      exit 0;
  fi
}
exract_file(){
	

	OLDDATE="NEW"
	COUNTER=0
    SPLITCOUNTER=1
	i=0
	
    if  [ $SPLIT -eq 1 ] 
	then
		FILEOUTNAME=${ORIGFILEOUTNAME}_${SPLITCOUNTER}_data.txt
    else
        FILEOUTNAME=${ORIGFILEOUTNAME}_time.txt
	fi
    
    echo "" >  ${FILEOUTNAME}
    
    
	while read LINE
	do
#		echo $LINE

    if [[ $LINE =~ $STARTDELIMITER ]]
	then
		WRITE=1
		((FOUND=$COUNTER+${i}))
		echo "found at $FOUND"
		echo $WRITE
	fi

	if  [ $WRITE -eq 1 ] &&  [[ $LINE =~ $STOPDELIMITER ]]
	then
		WRITE=0
        if  [ $SPLIT -eq 1 ] 
        then
            ((SPLITCOUNTER=SPLITCOUNTER+1))
            FILEOUTNAME=${ORIGFILEOUTNAME}_${SPLITCOUNTER}_data.txt
        fi
	fi


	if [ $WRITE -eq 1 ] 
	then
  		echo $LINE >> ${FILEOUTNAME}
	fi

	((i=i+1))
	
	if [ $i -ge 100 ]
	then
 	     ((COUNTER=COUNTER+i))
	     i=0
	     echo "At line ${COUNTER}"
	 fi
	done < ${LOCPATH}/${FILETOPARSE}
}

print_help(){

echo " read_and_get_from_file.sh <FILE_name> <PATH>  <start delimiter text> <end delimiter text>"

}

case $FILETOPARSE in
    -h|--help)
      print_help
      ;;
    *)
      echo "Running extract"
      ask_confirmation
      exract_file
      ;;
  esac 	
	 
