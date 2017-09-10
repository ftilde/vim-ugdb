if !has('python3')
    echo "Error: Required vim compiled with +python3"
    finish
endif

" Setup all required python functions in the environment.
" This function is expected to be called exactly once.
function! SetupPython()
python3 << EOF
import socket
import sys
import os
import json

# Saves the _identifier_ of the currently selected ugdb instance
ugdb_current_server = None

def ugdb_list_potential_server_sockets(socket_base_dir):
    # This is really just a
    def may_be_socket(path):
        return not (os.path.isfile(path) or os.path.isdir(path))

    try:
        return [f for f in os.listdir(socket_base_dir) if may_be_socket(os.path.join(socket_base_dir, f))]
    except:
        return []

class UgdbServer:
    def __init__(self, socket_path, identifier):
        self.path = os.path.join(socket_path, identifier)
        self.identifier = identifier
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

        try:
            self.sock.connect(self.path)
        except Exception as msg:
            print("Cannot connect to socket at {}:".format(self.path))
            print(msg)

    def set_breakpoint(self, file, line):
        return self.make_request("set_breakpoint", {
            "file": file,
            "line": int(line)
            })


    def make_request(self, function_name, parameters):
        # Encode request
        message_body = {
                "function": function_name,
                "parameters": parameters
                }
        encoded_message = json.dumps(message_body).encode('utf-8')
        message_len = len(encoded_message)

        header = "ugdb-ipc".encode('utf-8') + message_len.to_bytes(4, byteorder='little')

        request = header + encoded_message

        # Send constructed request
        #print('sending "{}"'.format(request))
        self.sock.sendall(request)

        # Receive and decode response header
        response_header = self.sock.recv(12)
        response_message_length = int.from_bytes(response_header[8:15], byteorder='little')

        # Receive response message
        amount_received = 0
        response_message = ""

        while amount_received < response_message_length:
            data = self.sock.recv(64)
            amount_received += len(data)
            response_message += data.decode('utf8')

        return response_message


def ugdb_list_servers(socket_base_dir):
    return [UgdbServer(socket_base_dir, identifier) for identifier in ugdb_list_potential_server_sockets(socket_base_dir)]

def ugdb_get_active_server(socket_base_dir):
    need_new_server = False
    servers = ugdb_list_servers(socket_base_dir)
    if not servers:
        return None

    matching_server = [s for s in servers if s.identifier == ugdb_current_server]

    if not matching_server:
        if len(servers) == 1:
            return servers[0]
        else:
            # TODO: Let the user decide or try to match from working directory (ugdb/vim)
            # Also, we can employ some heuristic once an identification command (or similar) is implemented in ugdb,
            # e.g.: Try to match the working directories of ugdb and the current vim instance
            return servers[0]
    else:
        return matching_server[0]

def ugdb_print_status(status):
    #vim.command('echom "{}"'.format(status))
    print(status)
EOF
endfunction

call SetupPython()

" Try to set a breakpoint at the specified line in the specified file.
" The "best fitting" ugdb instance is chosen as a target
function! SetBreakpoint(file, line)
python3 << EOF
import vim
import json

socket_base_dir = os.path.join(os.getenv('XDG_RUNTIME_DIR'), 'ugdb')
file = vim.eval("a:file")
line = vim.eval("a:line")

server = ugdb_get_active_server(socket_base_dir)
if server is None:
    ugdb_print_status("No active ugdb instance!")
else:
    response = server.set_breakpoint(file, line)
    ugdb_print_status("Tried to set breakpoint. Response is: '{}'".format(response))
EOF
endfunction

command! -nargs=0 UGDBBreakpoint call SetBreakpoint(@%, line('.'))
