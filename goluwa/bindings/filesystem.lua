local ffi = require("ffi")
local fs = {}
local last_error

if jit.os ~= "Windows" then
	ffi.cdef("char *strerror(int);")

	function last_error()
		local num = ffi.errno()
		local err = ffi.string(ffi.C.strerror(num))
		return err == "" and tostring(num) or err
	end

	do -- attributes
		local stat_struct

		if jit.os == "OSX" then
			stat_struct = ffi.typeof([[
            struct {
                uint32_t st_dev;
                uint16_t st_mode;
                uint16_t st_nlink;
                uint64_t st_ino;
                uint32_t st_uid;
                uint32_t st_gid;
                uint32_t st_rdev;
                size_t st_atime;
                long st_atime_nsec;
                size_t st_mtime;
                long st_mtime_nsec;
                size_t st_ctime;
                long st_ctime_nsec;
                size_t st_btime; 
                long st_btime_nsec;
                int64_t st_size;
                int64_t st_blocks;
                int32_t st_blksize;
                uint32_t st_flags;
                uint32_t st_gen;
                int32_t st_lspare;
                int64_t st_qspare[2];
            }
        ]])
		else
			if jit.arch == "x64" then
				stat_struct = ffi.typeof([[
                struct {
                    uint64_t st_dev;
                    uint64_t st_ino;
                    uint64_t st_nlink;
                    uint32_t st_mode;
                    uint32_t st_uid;
                    uint32_t st_gid;
                    uint32_t __pad0;
                    uint64_t st_rdev;
                    int64_t st_size;
                    int64_t st_blksize;
                    int64_t st_blocks;
                    uint64_t st_atime;
                    uint64_t st_atime_nsec;
                    uint64_t st_mtime;
                    uint64_t st_mtime_nsec;
                    uint64_t st_ctime;
                    uint64_t st_ctime_nsec;
                    int64_t __unused[3];
                }
            ]])
			else
				stat_struct = ffi.typeof([[
                struct {
                    uint64_t st_dev;
                    uint8_t __pad0[4];
                    uint32_t __st_ino;
                    uint32_t st_mode;
                    uint32_t st_nlink;
                    uint32_t st_uid;
                    uint32_t st_gid;
                    uint64_t st_rdev;
                    uint8_t __pad3[4];
                    int64_t st_size;
                    uint32_t st_blksize;
                    uint64_t st_blocks;
                    uint32_t st_atime;
                    uint32_t st_atime_nsec;
                    uint32_t st_mtime;
                    uint32_t st_mtime_nsec;
                    uint32_t st_ctime;
                    uint32_t st_ctime_nsec;
                    uint64_t st_ino;
                }
            ]])
			end
		end

		local statbox = ffi.typeof("$[1]", stat_struct)
		local stat_func
		local stat_func_link
		local DIRECTORY = 0x4000

		if jit.os == "OSX" then
			ffi.cdef[[int stat64(const char *path, void *buf);]]
			stat_func = ffi.C.stat64
			ffi.cdef[[int lstat64(const char *path, void *buf);]]
			stat_func_link = ffi.C.lstat64
		else
			ffi.cdef("unsigned long syscall(int number, ...);")
			local arch = jit.arch
			stat_func = function(path, buff)
				return ffi.C.syscall(arch == "x64" and 4 or 195, path, buff)
			end
			stat_func_link = function(path, buff)
				return ffi.C.syscall(arch == "x64" and 6 or 196, path, buff)
			end
		end

		function fs.get_attributes(path, link)
			local buff = statbox()
			local ret = link and stat_func_link(path, buff) or stat_func(path, buff)

			if ret == 0 then
				return {
					last_accessed = tonumber(buff[0].st_atime),
					last_changed = tonumber(buff[0].st_ctime),
					last_modified = tonumber(buff[0].st_mtime),
					type = bit.band(buff[0].st_mode, DIRECTORY) ~= 0 and "directory" or "file",
					size = tonumber(buff[0].st_size),
					mode = buff[0].st_mode,
					links = buff[0].st_nlink,
				}
			end

			return nil, last_error()
		end
	end

	do -- find files
		local dot = string.byte(".")

		local function is_dots(ptr)
			if ptr[0] == dot then
				if ptr[1] == dot and ptr[2] == 0 then return true end

				if ptr[1] == 0 then return true end
			end

			return false
		end

		-- NOTE: 64bit version
		local dirent_struct

		if jit.os == "OSX" then
			if jit.arch == "arm64" then
				dirent_struct = ffi.typeof([[
					struct {
					uint64_t d_ino;
					uint64_t d_seekoff;
					uint16_t d_reclen;
					uint16_t d_namlen;
					uint8_t d_type;
					char d_name[1024];
					}
				]])
				ffi.cdef([[$ *readdir(void *dirp);]], dirent_struct)
			else
				dirent_struct = ffi.typeof([[
					struct {
						uint64_t d_ino;
						uint64_t d_seekoff;
						uint16_t d_reclen;
						uint16_t d_namlen;
						uint8_t d_type;
						char d_name[1024];
					}
				]])
				ffi.cdef([[$ *readdir(void *dirp) asm("readdir$INODE64");]], dirent_struct)
			end
		else
			dirent_struct = ffi.typeof([[
				struct {
					uint64_t d_ino;
					int64_t d_off;
					unsigned short d_reclen;
					unsigned char d_type;
					char d_name[256];
				}
			]])
			ffi.cdef([[$ *readdir(void *dirp) asm("readdir64");]], dirent_struct)
		end

		ffi.cdef[[void *opendir(const char *name);]]
		ffi.cdef[[int closedir(void *dirp);]]

		function fs.get_files(path)
			local out = {}
			local ptr = ffi.C.opendir(path or "")

			if ptr == nil then return nil, last_error() end

			local i = 1

			while true do
				local dir_info = ffi.C.readdir(ptr)

				if dir_info == nil then break end

				if not is_dots(dir_info.d_name) then
					out[i] = ffi.string(dir_info.d_name)
					i = i + 1
				end
			end

			ffi.C.closedir(ptr)
			return out
		end

		function fs.walk(path, tbl, errors, can_traverse, files_only)
			tbl = tbl or {}
			local ptr = ffi.C.opendir(path or "")

			if ptr == nil then
				table.insert(errors, {path = path, error = last_error()})
				return
			end

			if not files_only then
				tbl.n = (tbl.n or 0) + 1
				tbl[tbl.n] = path
			end

			while true do
				local dir_info = ffi.C.readdir(ptr)

				if dir_info == nil then break end

				if not is_dots(dir_info.d_name) then
					local name = path .. ffi.string(dir_info.d_name)

					if dir_info.d_type == 4 then
						if not can_traverse or can_traverse(name) ~= false then
							fs.walk(name .. "/", tbl, errors, can_traverse, files_only)
						end
					else
						tbl.n = (tbl.n or 0) + 1
						tbl[tbl.n] = name
					end
				end
			end

			ffi.C.closedir(ptr)
			return tbl
		end
	end

	do
		ffi.cdef("int mkdir(const char *filename, uint32_t mode);")

		function fs.create_directory(path)
			if ffi.C.mkdir(path, 448) ~= 0 then return nil, last_error() end

			return true
		end
	end

	do
		ffi.cdef("int remove(const char *pathname);")

		function fs.remove_file(path)
			if ffi.C.remove(path) ~= 0 then return nil, last_error() end

			return true
		end
	end

	do
		ffi.cdef("int rmdir(const char *filename);")

		function fs.remove_directory(path)
			if ffi.C.rmdir(path) ~= 0 then return nil, last_error() end

			return true
		end
	end

	do
		ffi.cdef("int chdir(const char *filename);")

		function fs.set_current_directory(path)
			if ffi.C.chdir(path) ~= 0 then return nil, last_error() end

			return true
		end
	end

	do
		ffi.cdef("char *getcwd(char *buf, size_t size);")

		function fs.get_current_directory()
			local temp = ffi.new("char[1024]")
			return ffi.string(ffi.C.getcwd(temp, ffi.sizeof(temp)))
		end
	end
else
	ffi.cdef("uint32_t GetLastError();")
	ffi.cdef[[
        uint32_t FormatMessageA(
            uint32_t dwFlags,
            const void* lpSource,
            uint32_t dwMessageId,
            uint32_t dwLanguageId,
            char* lpBuffer,
            uint32_t nSize,
            va_list *Arguments
        );
    ]]
	local error_str = ffi.new("uint8_t[?]", 1024)
	local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000
	local FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200
	local error_flags = bit.bor(FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS)

	function last_error()
		local code = ffi.C.GetLastError()
		local numout = ffi.C.FormatMessageA(error_flags, nil, code, 0, error_str, 1023, nil)
		local err = numout ~= 0 and ffi.string(error_str, numout)

		if err and err:sub(-2) == "\r\n" then return err:sub(0, -3) end

		return err
	end

	local DIRECTORY = 0x10
	local time_struct = ffi.typeof([[
		struct {
			unsigned long high;
			unsigned long low;
		}
	]])

	do
		local time_type = ffi.typeof("uint64_t *")
		local tonumber = tonumber
		local POSIX_TIME = function(ptr)
			return tonumber(ffi.cast(time_type, ptr)[0] / 10000000 - 11644473600)
		end
		local file_attributes = ffi.typeof(
			[[
			struct {
				unsigned long dwFileAttributes;
				$ ftCreationTime;
				$ ftLastAccessTime;
				$ ftLastWriteTime;
				unsigned long nFileSizeHigh;
				unsigned long nFileSizeLow;
			}
		]],
			time_struct,
			time_struct,
			time_struct
		)
		ffi.cdef([[int GetFileAttributesExA(const char *, int, $ *);]], file_attributes)
		local info_box = ffi.typeof("$[1]", file_attributes)

		function fs.get_attributes(path)
			local info = info_box()

			if ffi.C.GetFileAttributesExA(path, 0, info) == 0 then
				return nil, last_error()
			end

			return {
				raw_info = info[0],
				creation_time = POSIX_TIME(info[0].ftCreationTime),
				last_accessed = POSIX_TIME(info[0].ftLastAccessTime),
				last_modified = POSIX_TIME(info[0].ftLastWriteTime),
				last_changed = -1, -- last permission changes
				size = info[0].nFileSizeLow,
				type = bit.band(info[0].dwFileAttributes, DIRECTORY) == DIRECTORY and
					"directory" or
					"file",
			}
		end
	end

	do
		local find_data_struct = ffi.typeof(
			[[
			struct {
				unsigned long dwFileAttributes;

				$ ftCreationTime;
				$ ftLastAccessTime;
				$ ftLastWriteTime;

				unsigned long nFileSizeHigh;
				unsigned long nFileSizeLow;

				unsigned long dwReserved0;
				unsigned long dwReserved1;

				char cFileName[260];
				char cAlternateFileName[14];
			}
		]],
			time_struct,
			time_struct,
			time_struct
		)
		ffi.cdef([[int FindNextFileA(void *, $ *);]], find_data_struct)
		ffi.cdef([[void *FindFirstFileA(const char *, $ *);]], find_data_struct)
		ffi.cdef[[int FindClose(void *);]]
		local dot = string.byte(".")

		local function is_dots(ptr)
			if ptr[0] == dot then
				if ptr[1] == dot and ptr[2] == 0 then return true end

				if ptr[1] == 0 then return true end
			end

			return false
		end

		local ffi_cast = ffi.cast
		local ffi_string = ffi.string
		local INVALID_FILE = ffi.cast("void *", -1)
		local data_box = ffi.typeof("$[1]", find_data_struct)
		local data = data_box()

		function fs.get_files(dir)
			if path == "" then path = "." end

			if dir:sub(-1) ~= "/" then dir = dir .. "/" end

			local handle = ffi.C.FindFirstFileA(dir .. "*", data)

			if handle == nil then return nil, last_error() end

			local out = {}

			if handle ~= INVALID_FILE then
				local i = 1

				repeat
					if not is_dots(data[0].cFileName) then
						out[i] = ffi_string(data[0].cFileName)
						i = i + 1
					end				
				until ffi.C.FindNextFileA(handle, data) == 0

				if ffi.C.FindClose(handle) == 0 then return nil, last_error() end
			end

			return out
		end

		function fs.walk(path, tbl, errors, can_traverse, files_only)
			tbl = tbl or {}
			local handle = ffi.C.FindFirstFileA(path .. "*", data)

			if handle == nil then
				table.insert(errors, {path = path, error = last_error()})
				return
			end

			if not files_only then
				tbl.n = (tbl.n or 0) + 1
				tbl[tbl.n] = path
			end

			if handle ~= INVALID_FILE then
				local i = 1

				repeat
					if not is_dots(data[0].cFileName) then
						local name = path .. ffi_string(data[0].cFileName)

						if bit.band(data[0].dwFileAttributes, DIRECTORY) == DIRECTORY then
							if not can_traverse or can_traverse(name) ~= false then
								fs.walk(name .. "/", tbl, errors)
							end
						else
							tbl.n = (tbl.n or 0) + 1
							tbl[tbl.n] = name
						end
					end				
				until ffi.C.FindNextFileA(handle, data) == 0

				if ffi.C.FindClose(handle) == 0 then return nil, last_error() end
			end

			return tbl
		end
	end

	do
		ffi.cdef[[unsigned long GetCurrentDirectoryA(unsigned long, char *);]]

		function fs.get_current_directory()
			local buffer = ffi.new("char[260]")
			local length = ffi.C.GetCurrentDirectoryA(260, buffer)
			return ffi.string(buffer, length):gsub("\\", "/")
		end
	end

	do
		ffi.cdef[[int SetCurrentDirectoryA(const char *);]]

		function fs.set_current_directory(path)
			if ffi.C.SetCurrentDirectoryA(path) == 0 then return nil, last_error() end

			return true
		end
	end

	do
		ffi.cdef[[int CreateDirectoryA(const char *, void *);]]

		function fs.create_directory(path)
			if ffi.C.CreateDirectoryA(path, nil) == 0 then return nil, last_error() end

			return true
		end
	end

	do
		ffi.cdef[[int DeleteFileA(const char *);]]

		function fs.remove_file(path)
			if ffi.C.DeleteFileA(path) == 0 then return nil, last_error() end

			return true
		end
	end

	do
		ffi.cdef[[int RemoveDirectoryA(const char *);]]

		function fs.remove_directory(path)
			if ffi.C.RemoveDirectoryA(path) == 0 then return nil, last_error() end

			return true
		end
	end
end

-- File I/O operations (cross-platform)
do
	-- FILE* operations (high-level, buffered I/O)
	if jit.os == "Windows" then
		ffi.cdef[[
			typedef struct FILE FILE;
			
			// Opening and closing
			FILE* fopen(const char* path, const char* mode);
			FILE* _fdopen(int fd, const char* mode);
			FILE* freopen(const char* path, const char* mode, FILE* stream);
			int fclose(FILE* stream);
		]]
	else
		ffi.cdef[[
			typedef struct FILE FILE;
			
			// Opening and closing
			FILE* fopen(const char* path, const char* mode);
			FILE* fdopen(int fd, const char* mode);
			FILE* freopen(const char* path, const char* mode, FILE* stream);
			int fclose(FILE* stream);
		]]
	end
	
	ffi.cdef[[
		
		// Reading
		size_t fread(void* ptr, size_t size, size_t count, FILE* stream);
		int fgetc(FILE* stream);
		char* fgets(char* str, int count, FILE* stream);
		int getc(FILE* stream);
		int ungetc(int c, FILE* stream);
		
		// Writing
		size_t fwrite(const void* ptr, size_t size, size_t count, FILE* stream);
		int fputc(int c, FILE* stream);
		int fputs(const char* str, FILE* stream);
		int putc(int c, FILE* stream);
		int fprintf(FILE* stream, const char* fmt, ...);
		
		// Position and seeking
		int fseek(FILE* stream, long offset, int whence);
		long ftell(FILE* stream);
		void rewind(FILE* stream);
		int fgetpos(FILE* stream, void* pos);
		int fsetpos(FILE* stream, const void* pos);
		
		// Buffering and flushing
		int fflush(FILE* stream);
		void setbuf(FILE* stream, char* buffer);
		int setvbuf(FILE* stream, char* buffer, int mode, size_t size);
		
		// Error handling
		int feof(FILE* stream);
		int ferror(FILE* stream);
		void clearerr(FILE* stream);
		
		// File descriptor operations
		int _fileno(FILE* stream);
	]]

	if jit.os ~= "Windows" then
		ffi.cdef[[
			int fileno(FILE* stream);
			// Standard streams
			extern FILE* stdin;
			extern FILE* stdout;
			extern FILE* stderr;
		]]
	end

	-- Seek constants
	fs.SEEK_SET = 0
	fs.SEEK_CUR = 1
	fs.SEEK_END = 2
	-- Buffering modes
	fs.IOFBF = 0 -- full buffering
	fs.IOLBF = 1 -- line buffering
	fs.IONBF = 2 -- no buffering
	-- File mode helpers
	fs.FILE_MODES = {
		read = "r",
		write = "w",
		append = "a",
		read_update = "r+",
		write_update = "w+",
		append_update = "a+",
		read_binary = "rb",
		write_binary = "wb",
		append_binary = "ab",
		read_update_binary = "r+b",
		write_update_binary = "w+b",
		append_update_binary = "a+b",
	}

	function fs.fopen(path, mode)
		local file = ffi.C.fopen(path, mode or "r")

		if file == nil then return nil, last_error() end

		return file
	end

	function fs.fdopen(fd, mode)
		local fdopen_func = jit.os == "Windows" and ffi.C._fdopen or ffi.C.fdopen
		local file = fdopen_func(fd, mode or "r")

		if file == nil then return nil, last_error() end

		return file
	end

	function fs.fclose(file)
		if ffi.C.fclose(file) ~= 0 then return nil, last_error() end

		return true
	end

	function fs.fread(file, size, count)
		count = count or 1
		local buffer = ffi.new("uint8_t[?]", size * count)
		local bytes_read = ffi.C.fread(buffer, size, count, file)

		if bytes_read == 0 and ffi.C.ferror(file) ~= 0 then
			return nil, last_error()
		end

		return ffi.string(buffer, bytes_read * size), bytes_read
	end

	function fs.fwrite(file, data, size, count)
		size = size or 1
		count = count or #data / size
		local bytes_written = ffi.C.fwrite(data, size, count, file)

		if bytes_written < count then return nil, last_error() end

		return bytes_written
	end

	function fs.fseek(file, offset, whence)
		whence = whence or fs.SEEK_SET

		if ffi.C.fseek(file, offset, whence) ~= 0 then return nil, last_error() end

		return true
	end

	function fs.ftell(file)
		local pos = ffi.C.ftell(file)

		if pos == -1 then return nil, last_error() end

		return pos
	end

	function fs.fflush(file)
		if ffi.C.fflush(file) ~= 0 then return nil, last_error() end

		return true
	end

	function fs.feof(file)
		return ffi.C.feof(file) ~= 0
	end

	function fs.ferror(file)
		return ffi.C.ferror(file) ~= 0
	end

	function fs.fileno(file)
		local fd
		if jit.os == "Windows" then
			fd = ffi.C._fileno(file)
		else
			fd = ffi.C.fileno(file)
		end

		if fd == -1 then return nil, last_error() end

		return fd
	end

	do
		local meta = {}
		meta.__index = meta

		function meta:close()
			return fs.fclose(self.file)
		end

		function meta:read(size, count)
			return fs.fread(self.file, size, count)
		end

		function meta:write(data, size, count)
			return fs.fwrite(self.file, data, size, count)
		end

		function meta:seek(offset, whence)
			return fs.fseek(self.file, offset, whence)
		end

		function meta:tell()
			return fs.ftell(self.file)
		end

		function meta:flush()
			return fs.fflush(self.file)
		end

		function meta:eof()
			return fs.feof(self.file)
		end

		function meta:error()
			return fs.ferror(self.file)
		end

		function meta:get_fileno()
			return fs.fileno(self.file)
		end

		function fs.file_open(path, mode)
			local f, err

			if tonumber(path) then
				f, err = fs.fdopen(path, mode)
			else
				f, err = fs.fopen(path, mode)
			end

			if not f then return nil, err end

			local self = setmetatable({file = f}, meta)
			return self
		end
	end
end

-- Low-level file descriptor operations
do
	if jit.os ~= "Windows" then
		ffi.cdef[[
			// File descriptor operations
			int open(const char* path, int flags, ...);
			int creat(const char* path, unsigned int mode);
			ssize_t read(int fd, void* buf, size_t count);
			ssize_t write(int fd, const void* buf, size_t count);
			int close(int fd);
			
			// File control and duplication
			int dup(int oldfd);
			int dup2(int oldfd, int newfd);
			int fcntl(int fd, int cmd, ...);
			int ioctl(int fd, unsigned long request, ...);
			
			// Seeking
			long lseek(int fd, long offset, int whence);
			
			// Pipe operations
			int pipe(int pipefd[2]);
		]]
		-- Open flags
		fs.O_RDONLY = 0x0000
		fs.O_WRONLY = 0x0001
		fs.O_RDWR = 0x0002
		fs.O_CREAT = 0x0040
		fs.O_EXCL = 0x0080
		fs.O_TRUNC = 0x0200
		fs.O_APPEND = 0x0400
		fs.O_NONBLOCK = jit.os == "OSX" and 0x0004 or 0x0800
		fs.O_SYNC = jit.os == "OSX" and 0x0080 or 0x1000
		fs.O_CLOEXEC = jit.os == "OSX" and 0x1000000 or 0x80000
		-- File control commands
		fs.F_DUPFD = 0
		fs.F_GETFD = 1
		fs.F_SETFD = 2
		fs.F_GETFL = 3
		fs.F_SETFL = 4
		fs.F_GETLK = jit.os == "OSX" and 7 or 5
		fs.F_SETLK = jit.os == "OSX" and 8 or 6
		fs.F_SETLKW = jit.os == "OSX" and 9 or 7
		-- File descriptor flags
		fs.FD_CLOEXEC = 1
		-- Standard file descriptors
		fs.STDIN_FILENO = 0
		fs.STDOUT_FILENO = 1
		fs.STDERR_FILENO = 2

		function fs.fd_open(path, flags, mode)
			mode = mode or 0x1B6 -- 0666 octal
			local fd = ffi.C.open(path, flags, mode)

			if fd == -1 then return nil, last_error() end

			return fd
		end

		function fs.fd_read(fd, size)
			local buffer = ffi.new("uint8_t[?]", size)
			local bytes_read = ffi.C.read(fd, buffer, size)

			if bytes_read == -1 then return nil, last_error() end

			return ffi.string(buffer, bytes_read), bytes_read
		end

		function fs.fd_write(fd, data)
			local bytes_written = ffi.C.write(fd, data, #data)

			if bytes_written == -1 then return nil, last_error() end

			return bytes_written
		end

		function fs.fd_close(fd)
			if ffi.C.close(fd) ~= 0 then return nil, last_error() end

			return true
		end

		function fs.fd_dup(oldfd)
			local newfd = ffi.C.dup(oldfd)

			if newfd == -1 then return nil, last_error() end

			return newfd
		end

		function fs.fd_dup2(oldfd, newfd)
			if ffi.C.dup2(oldfd, newfd) == -1 then return nil, last_error() end

			return newfd
		end

		function fs.fd_pipe()
			local pipefd = ffi.new("int[2]")

			if ffi.C.pipe(pipefd) == -1 then return nil, last_error() end

			return pipefd[0], pipefd[1]
		end

		function fs.fd_fcntl(fd, cmd, arg)
			local result

			if arg ~= nil then
				result = ffi.C.fcntl(fd, cmd, ffi.cast("int", arg))
			else
				result = ffi.C.fcntl(fd, cmd)
			end

			if result == -1 then return nil, last_error() end

			return result
		end

		function fs.fd_set_nonblocking(fd, nonblock)
			local flags = ffi.C.fcntl(fd, fs.F_GETFL)

			if flags == -1 then return nil, last_error() end

			if nonblock then
				flags = bit.bor(flags, fs.O_NONBLOCK)
			else
				flags = bit.band(flags, bit.bnot(fs.O_NONBLOCK))
			end

			if ffi.C.fcntl(fd, fs.F_SETFL, ffi.cast("int", flags)) == -1 then
				return nil, last_error()
			end

			return true
		end

		function fs.fd_lseek(fd, offset, whence)
			whence = whence or fs.SEEK_SET
			local pos = ffi.C.lseek(fd, offset, whence)

			if pos == -1 then return nil, last_error() end

			return pos
		end
	else
		-- Windows file descriptor operations
		ffi.cdef[[
			int _open(const char* path, int flags, ...);
			int _read(int fd, void* buf, unsigned int count);
			int _write(int fd, const void* buf, unsigned int count);
			int _close(int fd);
			int _dup(int fd);
			int _dup2(int oldfd, int newfd);
			long _lseek(int fd, long offset, int whence);
			int _pipe(int* pipefd, unsigned int size, int textmode);
			int _setmode(int fd, int mode);
			
			// For non-blocking pipe reads
			void* _get_osfhandle(int fd);
			int PeekNamedPipe(
				void* hNamedPipe,
				void* lpBuffer,
				uint32_t nBufferSize,
				uint32_t* lpBytesRead,
				uint32_t* lpTotalBytesAvail,
				uint32_t* lpBytesLeftThisMessage
			);
		]]
		-- Open flags (Windows)
		fs.O_RDONLY = 0x0000
		fs.O_WRONLY = 0x0001
		fs.O_RDWR = 0x0002
		fs.O_APPEND = 0x0008
		fs.O_CREAT = 0x0100
		fs.O_TRUNC = 0x0200
		fs.O_EXCL = 0x0400
		fs.O_TEXT = 0x4000
		fs.O_BINARY = 0x8000
		fs.O_NOINHERIT = 0x0080
		-- File modes
		fs.O_IREAD = 0x0100
		fs.O_IWRITE = 0x0080
		-- Standard file descriptors
		fs.STDIN_FILENO = 0
		fs.STDOUT_FILENO = 1
		fs.STDERR_FILENO = 2

		function fs.fd_open(path, flags, mode)
			mode = mode or bit.bor(fs.O_IREAD, fs.O_IWRITE)
			local fd = ffi.C._open(path, flags, mode)

			if fd == -1 then return nil, last_error() end

			return fd
		end

		function fs.fd_read(fd, size)
			if jit.os == "Windows" then
				-- Check if data is available first (non-blocking behavior)
				local handle = ffi.C._get_osfhandle(fd)
				local avail = ffi.new("uint32_t[1]")
				
				-- PeekNamedPipe to check available bytes
				local peek_result = ffi.C.PeekNamedPipe(handle, nil, 0, nil, avail, nil)
				
				if peek_result == 0 or avail[0] == 0 then
					-- No data available or error
					return "", 0
				end
				
				-- Read available data (up to size)
				local to_read = math.min(size, avail[0])
				local buffer = ffi.new("uint8_t[?]", to_read)
				local bytes_read = ffi.C._read(fd, buffer, to_read)
				
				if bytes_read == -1 then return nil, last_error() end
				
				return ffi.string(buffer, bytes_read), bytes_read
			else
				local buffer = ffi.new("uint8_t[?]", size)
				local bytes_read = ffi.C._read(fd, buffer, size)

				if bytes_read == -1 then return nil, last_error() end

				return ffi.string(buffer, bytes_read), bytes_read
			end
		end

		function fs.fd_write(fd, data)
			local bytes_written = ffi.C._write(fd, data, #data)

			if bytes_written == -1 then return nil, last_error() end

			return bytes_written
		end

		function fs.fd_close(fd)
			if ffi.C._close(fd) ~= 0 then return nil, last_error() end

			return true
		end

		function fs.fd_dup(oldfd)
			local newfd = ffi.C._dup(oldfd)

			if newfd == -1 then return nil, last_error() end

			return newfd
		end

		function fs.fd_dup2(oldfd, newfd)
			if ffi.C._dup2(oldfd, newfd) == -1 then return nil, last_error() end

			return newfd
		end

		function fs.fd_pipe(size, textmode)
			size = size or 4096
			textmode = textmode or fs.O_BINARY
			local pipefd = ffi.new("int[2]")

			if ffi.C._pipe(pipefd, size, textmode) == -1 then
				return nil, last_error()
			end

			return pipefd[0], pipefd[1]
		end

		function fs.fd_lseek(fd, offset, whence)
			whence = whence or fs.SEEK_SET
			local pos = ffi.C._lseek(fd, offset, whence)

			if pos == -1 then return nil, last_error() end

			return pos
		end

		function fs.fd_setmode(fd, mode)
			if ffi.C._setmode(fd, mode) == -1 then return nil, last_error() end

			return true
		end
	end

	do
		local meta = {}
		meta.__index = meta

		function meta:close()
			return fs.fd_close(self.fd)
		end

		function meta:read(size)
			return fs.fd_read(self.fd, size)
		end

		function meta:write(data)
			return fs.fd_write(self.fd, data)
		end

		function meta:seek(offset, whence)
			return fs.fd_lseek(self.fd, offset, whence)
		end

		function meta:dup(target)
			if target then
				-- dup2 behavior: duplicate self into target
				local new = type(target) == "table" and target.fd or target
				local fd, err = fs.fd_dup2(self.fd, new)

				if not fd then return nil, err end

				return fd
			else
				-- dup behavior: create new duplicate
				local fd, err = fs.fd_dup(self.fd)

				if not fd then return nil, err end

				return setmetatable({fd = fd}, meta)
			end
		end

		function meta:set_nonblocking(nonblock)
			if jit.os == "Windows" then
				-- On Windows pipes are always blocking, but we can work around this
				-- by checking data availability before reading
				return true
			end
			return fs.fd_set_nonblocking(self.fd, nonblock)
		end

		if jit.os == "Windows" then
			function meta:setmode(mode)
				return fs.fd_setmode(self.fd, mode)
			end
			
			-- Check if data is available to read without blocking
			function meta:has_data()
				-- Try to read 0 bytes to test availability
				-- On Windows, we'll just return true and handle EAGAIN-like behavior
				-- by returning empty string on no data
				return true
			end
		end

		function fs.get_read_write_fd_pipes()
			local read_fd, write_fd, err = fs.fd_pipe()

			if not read_fd then return nil, err end

			return setmetatable({fd = read_fd}, meta), setmetatable({fd = write_fd}, meta)
		end

		local fd_open_raw = fs.fd_open

		function fs.fd_open_object(path, flags, mode)
			local fd, err = fd_open_raw(path, flags, mode)

			if not fd then return nil, err end

			return setmetatable({fd = fd}, meta)
		end

		-- High-level dup2 that accepts fd objects
		function fs.dup2(oldfd_obj, newfd_obj)
			local old = type(oldfd_obj) == "table" and oldfd_obj.fd or oldfd_obj
			local new = type(newfd_obj) == "table" and newfd_obj.fd or newfd_obj
			return fs.fd_dup2(old, new)
		end

		-- Standard file descriptor objects
		fs.fd = {
			stdin = setmetatable({fd = fs.STDIN_FILENO}, meta),
			stdout = setmetatable({fd = fs.STDOUT_FILENO}, meta),
			stderr = setmetatable({fd = fs.STDERR_FILENO}, meta),
		}
	end
end

return fs
