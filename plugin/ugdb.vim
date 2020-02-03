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
        self.sock.settimeout(1.0) #1000ms ought to be enough for everyone

        #might fail and throw and exception
        self.sock.connect(self.path)

    def set_breakpoint(self, file, line):
        return self.make_request("set_breakpoint", {
            "file": file,
            "line": int(line)
            })

    def get_instance_info(self):
        return self.make_request("get_instance_info", {})

    def get_working_directory(self):
        info = self.get_instance_info()
        if info and info.get('type') == 'success' and info.get('result'):
            return info['result'].get('working_directory')
        else:
            return None

    def make_request(self, function_name, parameters):
        try:
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
        except OSError:
            return None


def ugdb_list_servers(socket_base_dir):
    result = []
    for identifier in ugdb_list_potential_server_sockets(socket_base_dir):
        try:
            result.append(UgdbServer(socket_base_dir, identifier))
        except OSError:
            pass #Ignore dead servers
    return result

def ugdb_interactive_server_select(servers):
    while True:
        id = 0
        for s in servers:
            wd = s.get_working_directory()
            if wd:
                ugdb_print_status("{}: {}".format(id, wd))
                id += 1

        selection = ugdb_getchar()
        if selection is None or selection in [13, 27, 0, 3]:
            return None
        selection_char = chr(selection);
        try:
            selection_int = int(selection_char)
            if selection_int < id:
                wd = s.get_working_directory()
                if wd:
                    ugdb_print_status("Selected: {} ({})".format(selection_int, wd))
                    return servers[selection_int]
                else:
                    ugdb_print_status("Selected server disconnected", "ErrorMsg");
                    return None
        except ValueError:
            pass
        ugdb_print_status("Invalid selection: {}".format(selection_char), "ErrorMsg")

def ugdb_set_active_server(socket_base_dir):
    global ugdb_current_server
    servers = ugdb_list_servers(socket_base_dir)
    if not servers:
        ugdb_print_status("No active ugdb servers.", "ErrorMsg")
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
        return None

    matching_server = [s for s in servers if s.identifier == ugdb_current_server]

    new_server = None
    if not matching_server:
        if len(servers) == 1:
            new_server = servers[0]
        else:
            # Employ heuristic: Try to match the working directories of ugdb and the current vim instance
            current_dir = os.getcwd()
            best_matching_servers = []
            best_path = ""
            longest_common_path_len = 0
            for server in servers:
                wd = server.get_working_directory()
                if wd:
                    common_path_len = len(os.path.commonprefix([current_dir, wd]))
                    if common_path_len >= longest_common_path_len:
                        if common_path_len > longest_common_path_len:
                            best_matching_servers = []
                        best_matching_servers.append(server)
                        best_path = wd
                        longest_common_path_len = common_path_len

            if len(best_matching_servers) != 1:
                ugdb_print_status("Failed to automatically select instance. Please choose manually:", "WarningMsg")
                new_server = ugdb_interactive_server_select(servers)
            else:
                ugdb_print_status("Automatically selected ugdb server at {}".format(best_path))
                new_server = best_matching_servers[0]
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

def ugdb_print_status(status, highlight=None):
    if highlight:
        vim.command('echohl {}'.format(highlight))
        vim.command('echo "{}"'.format(status))
        vim.command('echohl None')
    else:
        vim.command('echo "{}"'.format(status))
        #print(status)
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
    ugdb_print_status("No active ugdb instance!", "ErrorMsg")
else:
    response = server.set_breakpoint(file, line)
    if response:
        type = response.get("type")
        result = response.get("result")
        reason = response.get("reason")
        details = response.get("details")
        if type == "success" and result:
            ugdb_print_status(result)
        elif type == "error" and reason:
            if details:
                ugdb_print_status("{} {}".format(reason, details), "ErrorMsg")
            else:
                ugdb_print_status(reason, "ErrorMsg")
        else:
            ugdb_print_status("Tried to set breakpoint. Invalid Response: '{}'".format(response), "ErrorMsg")
    else:
        ugdb_print_status("Tried to set breakpoint, but got no response", "ErrorMsg")
EOF
endfunction


" ----------------------------------------------------------------------------
" Public vim commands --------------------------------------------------------
" ----------------------------------------------------------------------------
command! -nargs=0 UGDBBreakpoint call s:SetBreakpoint(@%, line('.'))
command! -nargs=0 UGDBSelectInstance call s:SelectInstance()
