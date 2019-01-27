" ----------------------------------------------------------------------------
" Setup ----------------------------------------------------------------------
" ----------------------------------------------------------------------------
if !has('python3')
    echo "Error: Required vim compiled with +python3"
    finish
endif

" Setup all required python functions in the environment.
" This function is expected to be called exactly once.
function! UGDBSetupPython()
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

    def get_instance_info(self):
        return self.make_request("get_instance_info", {})

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

        return json.loads(response_message)


def ugdb_list_servers(socket_base_dir):
    return [UgdbServer(socket_base_dir, identifier) for identifier in ugdb_list_potential_server_sockets(socket_base_dir)]

def ugdb_interactive_server_select(servers):
    while True:
        id = 0
        for s in servers:
            try:
                info = s.get_instance_info()
                if info['type'] == 'success':
                    print("{}: {}".format(id, info['result']['working_directory']))
                    id += 1
            except OSError:
                pass # A crashing ugdb instance may have left a pipe behind

        selection = ugdb_getchar()
        if selection is None or selection in [13, 27, 0, 3]:
            return None
        selection_char = chr(selection);
        try:
            selection_int = int(selection_char)
            if selection_int < id:
                info = s.get_instance_info()
                if info['type'] == 'success':
                    print("Selected: {} ({})".format(selection_int, info['result']['working_directory']))
                    return servers[selection_int]
                else:
                    print("Selected server disconnected");
                    return None
        except ValueError:
            pass
        print("Invalid selection: {}".format(selection_char))

def ugdb_set_active_server(socket_base_dir):
    global ugdb_current_server
    servers = ugdb_list_servers(socket_base_dir)
    if not servers:
        print("No active ugdb servers.")
        return

    new_server = ugdb_interactive_server_select(servers)

    if new_server is None:
        ugdb_current_server = None
    else:
        ugdb_current_server = new_server.identifier

def ugdb_get_active_server(socket_base_dir):
    global ugdb_current_server

    need_new_server = False
    servers = ugdb_list_servers(socket_base_dir)
    if not servers:
        print("No active ugdb servers.")
        return None

    matching_server = [s for s in servers if s.identifier == ugdb_current_server]

    new_server = None
    if not matching_server:
        if len(servers) == 1:
            new_server = servers[0]
        else:
            # TODO: we can employ some heuristic once an identification command (or similar) is implemented in ugdb,
            # e.g.: Try to match the working directories of ugdb and the current vim instance
            print("Failed to automatically instance. Please choose manually:")
            new_server = ugdb_interactive_server_select(servers)
    else:
        new_server = matching_server[0]

    if new_server is None:
        ugdb_current_server = None
    else:
        ugdb_current_server = new_server.identifier
    return new_server

def ugdb_getchar():
    charcode_str = vim.eval('getchar()')

    if len(charcode_str) == 0:
        return None
    else:
        return int(charcode_str)

def ugdb_read_line():
    line = ""
    while True:
        charcode = ugdb_getchar()
        if charcode is None or charcode == 13 or charcode == 27 or charcode == 0 or charcode == 3:
            break;
        char = chr(charcode)

        #print(char, end='')
        #sys.stdout.flush()
        line += char

    return line

def ugdb_print_status(status):
    #vim.command('echom "{}"'.format(status))
    print(status)
EOF
endfunction

call UGDBSetupPython()


" ----------------------------------------------------------------------------
" Vim function implementation ------------------------------------------------
" ----------------------------------------------------------------------------

" Manually select the ugdb instance to connect to.
function! s:SelectInstance()
python3 << EOF
socket_base_dir = os.path.join(os.getenv('XDG_RUNTIME_DIR'), 'ugdb')
ugdb_set_active_server(socket_base_dir)
EOF
endfunction

" Try to set a breakpoint at the specified line in the specified file.
" The currently active ugdb instance is chosen as a target.
" If no instance is selected, a selection has to be made first.
function! s:SetBreakpoint(file, line)
python3 << EOF
import vim

socket_base_dir = os.path.join(os.getenv('XDG_RUNTIME_DIR'), 'ugdb')
file = vim.eval("a:file")
line = vim.eval("a:line")

server = ugdb_get_active_server(socket_base_dir)
if server is None:
    ugdb_print_status("No active ugdb instance!")
else:
    response = server.set_breakpoint(file, line)
    type = response.get("type")
    result = response.get("result")
    reason = response.get("reason")
    details = response.get("details")
    if type == "success" and result:
        ugdb_print_status(result)
    elif type == "error" and reason:
        if details:
            ugdb_print_status("{} {}".format(reason, details))
        else:
            ugdb_print_status(reason)
    else:
        ugdb_print_status("Tried to set breakpoint. Invalid Response: '{}'".format(response))
EOF
endfunction


" ----------------------------------------------------------------------------
" Public vim commands --------------------------------------------------------
" ----------------------------------------------------------------------------
command! -nargs=0 UGDBBreakpoint call s:SetBreakpoint(@%, line('.'))
command! -nargs=0 UGDBSelectInstance call s:SelectInstance()
