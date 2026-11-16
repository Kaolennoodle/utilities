#!/usr/bin/env python3
"""Send a real DNS query through SOCKS5 UDP ASSOCIATE and validate the reply."""
import socket, struct, sys
port=int(sys.argv[1]); tcp=socket.create_connection(('127.0.0.1',port),timeout=10)
tcp.sendall(b'\x05\x01\x00'); assert tcp.recv(2)==b'\x05\x00'
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); udp.bind(('127.0.0.1',0)); udp.settimeout(15)
tcp.sendall(b'\x05\x03\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',udp.getsockname()[1]))
reply=tcp.recv(128); assert reply[:2]==b'\x05\x00',reply
assert reply[3]==1,reply
relay=(socket.inet_ntoa(reply[4:8]),struct.unpack('!H',reply[8:10])[0])
query=struct.pack('!6H',0x47ab,0x0100,1,0,0,0)+b'\x07example\x03com\x00'+struct.pack('!2H',1,1)
packet=b'\x00\x00\x00\x01'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+query
udp.sendto(packet,relay); data,_=udp.recvfrom(8192)
assert data[:3]==b'\x00\x00\x00'
pos={1:10,4:22}.get(data[3]); pos=pos if pos else 7+data[4]
header=struct.unpack('!6H',data[pos:pos+12]); assert header[0]==0x47ab and header[1]&0x8000 and header[3]>0,header
print('PASS SOCKS5 UDP DNS forwarding, answers='+str(header[3]))
tcp.close(); udp.close()
