#!/usr/bin/env python3
"""Verify HTTP/3 with public CA validation, including a real 404 response."""
import asyncio, hashlib, sys
from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3Connection, H3_ALPN
from aioquic.h3.events import HeadersReceived, DataReceived
from aioquic.quic.configuration import QuicConfiguration

class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.responses = {}
    def quic_event_received(self, event):
        for item in self.http.handle_event(event):
            if isinstance(item, (HeadersReceived, DataReceived)):
                future, headers, body = self.responses[item.stream_id]
                if isinstance(item, HeadersReceived): headers.extend(item.headers)
                else: body.extend(item.data)
                if item.stream_ended and not future.done(): future.set_result((dict(headers), bytes(body)))
    async def get(self, host, path):
        stream = self._quic.get_next_available_stream_id()
        future = asyncio.get_running_loop().create_future()
        self.responses[stream] = (future, [], bytearray())
        self.http.send_headers(stream, [(b':method',b'GET'), (b':scheme',b'https'),
            (b':authority',host.encode()), (b':path',path.encode())], end_stream=True)
        self.transmit()
        return await asyncio.wait_for(future, 20)
async def main():
    host=sys.argv[1]
    config=QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, server_name=host, idle_timeout=12)
    async with connect(__import__('os').environ.get('HTTP3_CONNECT_IP', host),443,configuration=config,create_protocol=Client) as client:
        for path in sys.argv[2:] or ['/','/does-not-exist-test-404']:
            headers,body=await client.get(host,path)
            status=int(headers[b':status'])
            expected=404 if 'does-not-exist-test-404' in path else 200
            assert status==expected, (path,status)
            print('PASS HTTP/3',path,status,'bytes='+str(len(body)), 'sha256='+hashlib.sha256(body).hexdigest())
asyncio.run(main())
