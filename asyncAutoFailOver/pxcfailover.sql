CREATE DEFINER=`dba`@`%` PROCEDURE `grfailover`(IN timeout int, IN in_channel_name varchar(100))
    READS SQL DATA
    DETERMINISTIC
    SQL SECURITY INVOKER
BEGIN
DECLARE v_sql varchar (1000);
DECLARE v_uuid CHAR(36);
DECLARE i_last_error_number int;
DECLARE v_last_error_message varchar(4000);
DECLARE d_last_error_timestamp TIMESTAMP(6);
DECLARE v_member_host VARCHAR(100);
DECLARE i_member_port INT;
DECLARE v_member_uuid VARCHAR (100);
DECLARE v_member_state VARCHAR(50);
DECLARE v_member_role VARCHAR(10);
DECLARE v_p_uuid char(36);

DECLARE secondary_started timestamp(6);
DECLARE secondary_last_update timestamp(6);
DECLARE secondary_p_uuid char(36);

DECLARE my_replication_channel_status char(3);
DECLARE my_started timestamp(6);
DECLARE my_last_update timestamp(6);

DECLARE wait_timeout int;
DECLARE no_wait TINYINT;

SET no_wait = 1;
SET SQL_MODE='ALLOW_INVALID_DATES';


-- let us create the table if not EXISTS
if v_member_role = 'PRIMARY' THEN
		CREATE TABLE IF	NOT EXISTS percona.group_replication_failover_manager (
				server_uuid CHAR ( 36 ) NOT NULL PRIMARY KEY,
				HOST VARCHAR ( 255 ) NOT NULL,
				PORT INT NOT NULL DEFAULT 3306,
				channel_name VARCHAR ( 100 ) NOT NULL,
				gr_role VARCHAR ( 30 ) NOT NULL,
				STATUS VARCHAR ( 50 ),
				started TIMESTAMP ( 6 ),
				lastupdate TIMESTAMP ( 6 ),
				COMMENT VARCHAR ( 200 ) 
			) ENGINE = INNODB;
end if;


select @@server_uuid into v_uuid;


select member_host,member_port,member_id,member_state,member_role 			
			into v_member_host, i_member_port, v_member_uuid,v_member_state, v_member_role from performance_schema.replication_group_members where member_id = v_uuid;

select service_state,last_error_number,last_error_message,last_error_timestamp 
				into my_replication_channel_status, i_last_error_number,v_last_error_message,d_last_error_timestamp from performance_schema.replication_connection_status where channel_name = in_channel_name;

core_testing: BEGIN

if v_member_host is NOT null 
	AND v_member_uuid is NOT null 
	AND my_replication_channel_status is NOT NULL THEN
	select server_uuid into v_p_uuid from percona.group_replication_failover_manager where server_uuid = v_uuid;
		if v_p_uuid is null THEN
			-- there is no entry in the table let us add it 
			-- select "need to insert";
			
			if v_member_role != 'PRIMARY' THEN
					set global super_read_only=0;
				else 
					set my_last_update =now();
			end if;
			
			insert into percona.group_replication_failover_manager (server_uuid,host,port,channel_name,gr_role,`status`, started,lastupdate,`comment`) 
				values(v_uuid,v_member_host,i_member_port,in_channel_name,v_member_role,v_member_state,my_last_update,null,'Just inserted');

			if v_member_role != 'PRIMARY' THEN
				set global super_read_only=1;
			end if;
		end if; 
		
		-- if the node is NOT primary at this point I just EXIT
		if v_member_role != 'PRIMARY' THEN
				LEAVE core_testing;
		end if; 
		
		-- If a node become primary but it still see another Primary in the table and the time lastupdate is less than TIMEOUT then it will wait. 
		select server_uuid, lastupdate into secondary_p_uuid, secondary_last_update from percona.group_replication_failover_manager where server_uuid != v_uuid AND gr_role = 'PRIMARY' limit 1;
		
		if secondary_p_uuid is not null THEN
				set wait_timeout = TIMESTAMPDIFF(MINUTE,secondary_last_update,now()); 
				-- select concat("wait timeout ",wait_timeout);
				if wait_timeout < timeout THEN
					set no_wait = 0;
				else
				-- select concat("reset the secondary in ",wait_timeout, " wait ", no_wait);
				-- we reset the node that WAS a primary but now is not up to date anymore
					update percona.group_replication_failover_manager set started = null, lastupdate = null, gr_role = 'SECONDARY', comment = concat('Resetted by primary node ', v_uuid, ' at ', now() ) where server_uuid = secondary_p_uuid;
				end if;
		end if;
		
		if no_wait = 0 THEN
			-- select 'need to wait';
			update percona.group_replication_failover_manager set gr_role = 'PRIMARY',  comment = concat('Need to wait ',timeout,' minutes, passed: ' , wait_timeout) where server_uuid = v_uuid;
			LEAVE core_testing;
		end if;
		
		-- at this stage if replication is ON all good otherwise I need to start it
		if my_replication_channel_status != 'ON' then
 			select concat('Starting REPLICA for channel ',in_channel_name);
			SET v_sql = concat('START REPLICA for channel \'',in_channel_name,'\'');
			SET @s = v_sql;
        
      PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      DEALLOCATE PREPARE stmt1;
			
			update percona.group_replication_failover_manager set gr_role = 'PRIMARY', started = now(), comment = concat('REPLICA restarted for the channel ', in_channel_name) where server_uuid = v_uuid;
			
		end if;
		
		-- and now let us update the last mofified TIME
		update percona.group_replication_failover_manager set lastupdate = now() where server_uuid = v_uuid ; 
		-- select "all good";
 elseif v_member_host is null and v_member_uuid is null THEN
		select "The node is not in a Group Replication cluster";
		LEAVE core_testing;
 elseif my_replication_channel_status is NULL THEN
		select "channel name do not match any active channel";
		leave core_testing;
 end if;
 
 
END core_testing;

	
END