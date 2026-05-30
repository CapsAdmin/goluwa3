local ffi = require("ffi")
local fs = {}
local last_error

if jit.os ~= "Windows" then
	ffi.cdef("char *strerror(int);")

	if jit.os == "Linux" then
		ffi.cdef[[
			int inotify_init1(int flags);
			int inotify_add_watch(int fd, const char *pathname, uint32_t mask);
			int inotify_rm_watch(int fd, int wd);
			struct inotify_event {
				int      wd;
				uint32_t mask;
				uint32_t cookie;
				uint32_t len;
				char     name[];
			};
		]]
		fs.IN_NONBLOCK = 0x00000800
		fs.IN_CLOSE_WRITE = 0x00000008
		fs.IN_MOVED_TO = 0x00000080
		fs.IN_CREATE = 0x00000100
		fs.IN_DELETE = 0x00000200
		fs.IN_MODIFY = 0x00000002
		fs.IN_MOVE = 0x000000C0 -- IN_MOVED_FROM | IN_MOVED_TO
		fs.IN_MOVED_FROM = 0x00000040
		fs.IN_ISDIR = 0x40000000
	end

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
					char d_name[256];
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
						char d_name[256];
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
	ffi.cdef[[
		typedef struct _OVERLAPPED {
			uintptr_t Internal;
			uintptr_t InternalHigh;
			union {
				struct {
					uint32_t Offset;
					uint32_t OffsetHigh;
				};
				void* Pointer;
			};
			void* hEvent;
		} OVERLAPPED, *LPOVERLAPPED;

		void* CreateFileA(const char* lpFileName, uint32_t dwDesiredAccess, uint32_t dwShareMode, void* lpSecurityAttributes, uint32_t dwCreationDisposition, uint32_t dwFlagsAndAttributes, void* hTemplateFile);
		int ReadDirectoryChangesW(void* hDirectory, void* lpBuffer, uint32_t nBufferLength, int bWatchSubtree, uint32_t dwNotifyFilter, uint32_t* lpBytesReturned, LPOVERLAPPED lpOverlapped, void* lpCompletionRoutine);
		int CloseHandle(void* hObject);

		int MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int cbMultiByte, uint16_t* lpWideCharStr, int cchWideChar);
		int WideCharToMultiByte(uint32_t CodePage, uint32_t dwFlags, const uint16_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
	]]
	fs.FILE_LIST_DIRECTORY = 0x0001
	fs.FILE_SHARE_READ = 0x00000001
	fs.FILE_SHARE_WRITE = 0x00000002
	fs.FILE_SHARE_DELETE = 0x00000004
	fs.OPEN_EXISTING = 3
	fs.FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
	fs.FILE_FLAG_OVERLAPPED = 0x40000000
	fs.FILE_NOTIFY_CHANGE_FILE_NAME = 0x00000001
	fs.FILE_NOTIFY_CHANGE_DIR_NAME = 0x00000002
	fs.FILE_NOTIFY_CHANGE_ATTRIBUTES = 0x00000004
	fs.FILE_NOTIFY_CHANGE_SIZE = 0x00000008
	fs.FILE_NOTIFY_CHANGE_LAST_WRITE = 0x00000010
	fs.FILE_NOTIFY_CHANGE_LAST_ACCESS = 0x00000020
	fs.FILE_NOTIFY_CHANGE_CREATION = 0x00000040
	fs.FILE_NOTIFY_CHANGE_SECURITY = 0x00000100
	fs.FILE_ACTION_ADDED = 1
	fs.FILE_ACTION_REMOVED = 2
	fs.FILE_ACTION_MODIFIED = 3
	fs.FILE_ACTION_RENAMED_OLD_NAME = 4
	fs.FILE_ACTION_RENAMED_NEW_NAME = 5
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
		fs.O_CREAT = jit.os == "OSX" and 0x0200 or 0x0040
		fs.O_EXCL = jit.os == "OSX" and 0x0800 or 0x0080
		fs.O_TRUNC = jit.os == "OSX" and 0x0400 or 0x0200
		fs.O_APPEND = jit.os == "OSX" and 0x0008 or 0x0400
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
			local fd = ffi.C.open(path, flags, ffi.cast("int", mode))

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
			unsigned int GetFileType(void* hFile);
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
		fs.FILE_TYPE_UNKNOWN = 0x0000
		fs.FILE_TYPE_DISK = 0x0001
		fs.FILE_TYPE_CHAR = 0x0002
		fs.FILE_TYPE_PIPE = 0x0003
		-- Standard file descriptors
		fs.STDIN_FILENO = 0
		fs.STDOUT_FILENO = 1
		fs.STDERR_FILENO = 2

		function fs.fd_open(path, flags, mode)
			mode = mode or bit.bor(fs.O_IREAD, fs.O_IWRITE)

			if bit.band(flags, bit.bor(fs.O_BINARY, fs.O_TEXT)) == 0 then
				flags = bit.bor(flags, fs.O_BINARY)
			end

			local fd = ffi.C._open(path, flags, ffi.cast("int", mode))

			if fd == -1 then return nil, last_error() end

			return fd
		end

		function fs.fd_read(fd, size)
			if jit.os == "Windows" then
				local handle = ffi.C._get_osfhandle(fd)
				local file_type = handle ~= ffi.cast("void *", -1) and
					ffi.C.GetFileType(handle) or
					fs.FILE_TYPE_UNKNOWN

				if file_type == fs.FILE_TYPE_PIPE then
					local avail = ffi.new("uint32_t[1]")
					local peek_result = ffi.C.PeekNamedPipe(handle, nil, 0, nil, avail, nil)

					if peek_result == 0 or avail[0] == 0 then return "", 0 end

					size = math.min(size, avail[0])
				end

				local buffer = ffi.new("uint8_t[?]", size)
				local bytes_read = ffi.C._read(fd, buffer, size)

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
			mode = mode or 0x1B6 -- 0666 octal
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

do
	local ffi = require("ffi")
	local bit = require("bit")
	local event = import("goluwa/event.lua")

	local function trim_trailing_path_separator(path)
		if path == "/" then return path end

		if path:sub(-1) == "/" then return path:sub(1, -2) end

		return path
	end

	local function fix_path_slashes(path)
		return (path:gsub("\\", "/"):gsub("(/+)", "/"))
	end

	local function normalize_watch_paths(path)
		if type(path) == "table" then
			local paths = {}

			for i = 1, #path do
				paths[i] = trim_trailing_path_separator(fix_path_slashes(path[i]))
			end

			return paths
		end

		return {trim_trailing_path_separator(fix_path_slashes(path))}
	end

	local function normalize_watch_blacklist(blacklist)
		if not blacklist then return nil end

		if type(blacklist) == "string" then blacklist = {blacklist} end

		local normalized = {}

		for i = 1, #blacklist do
			normalized[i] = trim_trailing_path_separator(fix_path_slashes(blacklist[i]))
		end

		return normalized
	end

	local function is_blacklisted_watch_path(path, blacklist)
		if not blacklist then return false end

		for i = 1, #blacklist do
			local entry = blacklist[i]

			if path == entry or path:find("/" .. entry, 1, true) then return true end
		end

		return false
	end

	if jit.os == "Linux" then
		function fs.watch(path, callback, recursive, blacklist)
			local paths = normalize_watch_paths(path)
			blacklist = normalize_watch_blacklist(blacklist)
			local inotify_fd = ffi.C.inotify_init1(fs.IN_NONBLOCK)

			if inotify_fd == -1 then return nil, "Failed to initialize inotify" end

			local wd_to_path = {}

			local function add_watch(dir_path)
				if is_blacklisted_watch_path(dir_path, blacklist) then return -1 end

				local wd = ffi.C.inotify_add_watch(
					inotify_fd,
					dir_path,
					bit.bor(
						fs.IN_MODIFY,
						fs.IN_CREATE,
						fs.IN_DELETE,
						fs.IN_MOVE,
						fs.IN_CLOSE_WRITE
					)
				)

				if wd ~= -1 then wd_to_path[wd] = dir_path end

				return wd
			end

			local function add_recursive(dir_path)
				add_watch(dir_path)

				fs.walk(
					dir_path .. "/",
					nil,
					{},
					function(name)
						add_watch(name)
						return true
					end,
					true
				)
			end

			for _, dir_path in ipairs(paths) do
				if recursive then add_recursive(dir_path) else add_watch(dir_path) end
			end

			local buffer = ffi.new("char[4096]")
			local remove_event = event.AddListener("Update", {}, function()
				while true do
					local length = ffi.C.read(inotify_fd, buffer, 4096)

					if length <= 0 then break end

					local i = 0

					while i < length do
						local event = ffi.cast("struct inotify_event *", ffi.cast("char *", buffer) + i)
						local dir_path = wd_to_path[event.wd]

						if dir_path then
							local name = ffi.string(event.name)
							local full_path = dir_path .. "/" .. name
							local type = "modified"

							if bit.band(event.mask, fs.IN_CREATE) ~= 0 then
								type = "created"
							elseif bit.band(event.mask, fs.IN_DELETE) ~= 0 then
								type = "deleted"
							elseif bit.band(event.mask, fs.IN_MOVE) ~= 0 then
								type = "renamed"
							end

							if not is_blacklisted_watch_path(full_path, blacklist) then
								callback(full_path, type)
							end

							if
								recursive and
								bit.band(event.mask, fs.IN_ISDIR) ~= 0 and
								bit.band(bit.bor(fs.IN_CREATE, fs.IN_MOVED_TO), event.mask) ~= 0
							then
								add_recursive(full_path)
							end
						end

						i = i + ffi.sizeof("struct inotify_event") + event.len
					end
				end
			end)
			return function()
				for wd, _ in pairs(wd_to_path) do
					ffi.C.inotify_rm_watch(inotify_fd, wd)
				end

				ffi.C.close(inotify_fd)
				remove_event()
			end
		end
	elseif jit.os == "Windows" then
		function fs.watch(path, callback, recursive, blacklist)
			local paths = normalize_watch_paths(path)
			blacklist = normalize_watch_blacklist(blacklist)

			if #paths > 1 then
				local stops = {}

				for i = 1, #paths do
					local stop, err = fs.watch(paths[i], callback, recursive, blacklist)

					if not stop then
						for j = 1, #stops do
							stops[j]()
						end

						return nil, err
					end

					stops[i] = stop
				end

				return function()
					for i = 1, #stops do
						stops[i]()
					end
				end
			end

			path = paths[1]

			if is_blacklisted_watch_path(path, blacklist) then return function() end end

			local handle = ffi.C.CreateFileA(
				path,
				fs.FILE_LIST_DIRECTORY,
				7,
				nil,
				3,
				bit.bor(fs.FILE_FLAG_BACKUP_SEMANTICS, fs.FILE_FLAG_OVERLAPPED),
				nil
			)

			if handle == ffi.cast("void *", -1) then return nil end

			local buffer = ffi.new("uint8_t[4096]")
			local overlapped = ffi.new("OVERLAPPED")

			local function read_changes()
				ffi.C.ReadDirectoryChangesW(
					handle,
					buffer,
					4096,
					recursive and 1 or 0,
					bit.bor(
						fs.FILE_NOTIFY_CHANGE_FILE_NAME,
						fs.FILE_NOTIFY_CHANGE_DIR_NAME,
						fs.FILE_NOTIFY_CHANGE_LAST_WRITE
					),
					nil,
					overlapped,
					nil
				)
			end

			read_changes()
			local remove_event = event.AddListener("Update", {}, function()
				if ffi.cast("uintptr_t", overlapped.Internal) ~= 0x103 then
					local offset = 0

					while true do
						local info = ffi.cast(
							[[
						struct {
							uint32_t NextEntryOffset;
							uint32_t Action;
							uint32_t FileNameLength;
							uint16_t FileName[1];
						} *
					]],
							ffi.cast("char *", buffer) + offset
						)
						local filename_w = info.FileName
						local filename_len = info.FileNameLength / 2
						local bytes_needed = ffi.C.WideCharToMultiByte(
							65001,
							0,
							filename_w,
							filename_len,
							nil,
							0,
							nil,
							nil
						)
						local out_buf = ffi.new("char[?]", bytes_needed)
						ffi.C.WideCharToMultiByte(
							65001,
							0,
							filename_w,
							filename_len,
							out_buf,
							bytes_needed,
							nil,
							nil
						)
						local filename = ffi.string(out_buf, bytes_needed)
						local type = "modified"

						if info.Action == fs.FILE_ACTION_ADDED then
							type = "created"
						elseif info.Action == fs.FILE_ACTION_REMOVED then
							type = "deleted"
						elseif
							info.Action == fs.FILE_ACTION_RENAMED_OLD_NAME or
							info.Action == fs.FILE_ACTION_RENAMED_NEW_NAME
						then
							type = "renamed"
						end

						local full_path = path .. "/" .. filename

						if not is_blacklisted_watch_path(full_path, blacklist) then
							callback(full_path, type)
						end

						if info.NextEntryOffset == 0 then break end

						offset = offset + info.NextEntryOffset
					end

					read_changes()
				end
			end)
			return function()
				remove_event()
				ffi.C.CloseHandle(handle)
			end
		end
	elseif jit.os == "OSX" then
		local active_watches = {}
		local ffi = require("ffi")
		ffi.cdef([[
            typedef uint32_t FSEventStreamCreateFlags;
            typedef uint32_t FSEventStreamEventFlags;
            typedef uint64_t FSEventStreamEventId;
            typedef struct __FSEventStream *FSEventStreamRef;
            typedef void (*FSEventStreamCallback)(
                FSEventStreamRef streamRef,
                void *clientCallBackInfo,
                size_t numEvents,
                void *eventPaths,
                const FSEventStreamEventFlags eventFlags[],
                const FSEventStreamEventId eventIds[]
            );

            typedef struct {
                long version;
                void *info;
                void *retain;
                void *release;
                void *copyDescription;
            } FSEventStreamContext;

            FSEventStreamRef FSEventStreamCreate(
                void *allocator,
                FSEventStreamCallback callback,
                FSEventStreamContext *context,
                void *pathsToWatch,
                FSEventStreamEventId sinceWhen,
                double latency,
                FSEventStreamCreateFlags flags
            );

            void FSEventStreamScheduleWithRunLoop(
                FSEventStreamRef streamRef,
                void *runLoop,
                void *runLoopMode
            );

            bool FSEventStreamStart(FSEventStreamRef streamRef);
            void FSEventStreamStop(FSEventStreamRef streamRef);
            void FSEventStreamInvalidate(FSEventStreamRef streamRef);
            void FSEventStreamRelease(FSEventStreamRef streamRef);

            void *CFArrayCreate(void *allocator, const void **values, long numValues, void *callBacks);
            void CFRelease(void *cf);
            void *CFStringCreateWithCString(void *alloc, const char *cStr, uint32_t encoding);
            extern void *kCFRunLoopDefaultMode;
            void *CFRunLoopGetCurrent(void);
            int32_t CFRunLoopRunInMode(void *mode, double seconds, bool returnAfterSourceHandled);
            void CFRunLoopRun(void);
            void CFRunLoopStop(void *runLoop);

			typedef void (*CFRunLoopTimerCallBack)(void *timer, void *info);
			void *CFRunLoopTimerCreate(void *allocator, double fireDate, double interval, uint32_t flags, int32_t order, CFRunLoopTimerCallBack callout, void *context);
			void CFRunLoopAddTimer(void *rl, void *timer, void *mode);
        ]])
		fs.kFSEventStreamCreateFlagNone = 0x00000000
		fs.kFSEventStreamCreateFlagUseCFTypes = 0x00000001
		fs.kFSEventStreamCreateFlagNoDefer = 0x00000002
		fs.kFSEventStreamCreateFlagWatchRoot = 0x00000004
		fs.kFSEventStreamCreateFlagIgnoreSelf = 0x00000008
		fs.kFSEventStreamCreateFlagFileEvents = 0x00000010
		fs.kFSEventStreamEventFlagNone = 0x00000000
		fs.kFSEventStreamEventFlagMustScanSubDirs = 0x00000001
		fs.kFSEventStreamEventFlagUserDropped = 0x00000002
		fs.kFSEventStreamEventFlagKernelDropped = 0x00000004
		fs.kFSEventStreamEventFlagEventIdsWrapped = 0x00000008
		fs.kFSEventStreamEventFlagHistoryDone = 0x00000010
		fs.kFSEventStreamEventFlagRootChanged = 0x00000020
		fs.kFSEventStreamEventFlagMount = 0x00000040
		fs.kFSEventStreamEventFlagUnmount = 0x00000080
		fs.kFSEventStreamEventFlagItemCreated = 0x00000100
		fs.kFSEventStreamEventFlagItemRemoved = 0x00000200
		fs.kFSEventStreamEventFlagItemInodeMetaMod = 0x00000400
		fs.kFSEventStreamEventFlagItemRenamed = 0x00000800
		fs.kFSEventStreamEventFlagItemModified = 0x00001000
		fs.kFSEventStreamEventFlagItemFinderInfoMod = 0x00002000
		fs.kFSEventStreamEventFlagItemChangeOwner = 0x00004000
		fs.kFSEventStreamEventFlagItemXattrMod = 0x00008000
		fs.kFSEventStreamEventFlagItemIsFile = 0x00010000
		fs.kFSEventStreamEventFlagItemIsDir = 0x00020000
		fs.kFSEventStreamEventFlagItemIsSymlink = 0x00040000
		fs.kCFStringEncodingUTF8 = 0x08000100
		fs.kFSEventStreamEventIdSinceNow = 0xFFFFFFFFFFFFFFFFULL
		local ok, lib = pcall(ffi.load, "/System/Library/Frameworks/CoreServices.framework/CoreServices")

		if ok then
			fs.CoreServices = lib
		else
			-- Fallback to default if load fails, though CF functions might be missing
			fs.CoreServices = ffi.C
		end

		local function setup_macos_watch_timer(lib)
			if _G.MACOS_WATCH_TIMER_SETUP then return end

			_G.MACOS_WATCH_TIMER_SETUP = true

			local function timer_callback(timer, info) -- Just a dummy callback to keep the run loop alive and returning
			end

			local c_timer_callback = ffi.cast("CFRunLoopTimerCallBack", timer_callback)
			-- Anchor the callback
			active_watches[c_timer_callback] = {timer_callback, c_timer_callback}
			local rl = lib.CFRunLoopGetCurrent()
			local timer = lib.CFRunLoopTimerCreate(nil, 0, 0.1, 0, 0, c_timer_callback, nil)
			lib.CFRunLoopAddTimer(rl, timer, lib.kCFRunLoopDefaultMode)
		end

		function fs.watch(path, callback, recursive, blacklist)
			local lib = fs.CoreServices

			if not lib then return nil, "CoreServices not loaded" end

			local paths = normalize_watch_paths(path)
			blacklist = normalize_watch_blacklist(blacklist)
			local results = {}

			local function internal_callback(streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds)
				local paths_ptr = ffi.cast("char **", eventPaths)

				for i = 0, tonumber(numEvents) - 1 do
					local full_path = ffi.string(paths_ptr[i])

					if is_blacklisted_watch_path(full_path, blacklist) then goto continue end

					local flags = eventFlags[i]
					local type = "modified"

					if bit.band(flags, fs.kFSEventStreamEventFlagItemCreated) ~= 0 then
						type = "created"
					elseif bit.band(flags, fs.kFSEventStreamEventFlagItemRemoved) ~= 0 then
						type = "deleted"
					elseif bit.band(flags, fs.kFSEventStreamEventFlagItemRenamed) ~= 0 then
						type = "renamed"
					end

					table.insert(results, {path = full_path, type = type})

					::continue::
				end
			end

			if recursive == nil then recursive = true end

			local c_callback = ffi.cast("FSEventStreamCallback", internal_callback)
			local path_cfs = {}
			local path_ptrs = ffi.new("void *[?]", #paths)

			for i = 1, #paths do
				path_cfs[i] = lib.CFStringCreateWithCString(nil, paths[i], fs.kCFStringEncodingUTF8)
				path_ptrs[i - 1] = path_cfs[i]
			end

			local paths_array = lib.CFArrayCreate(nil, ffi.cast("const void **", path_ptrs), #paths, nil)
			local flags = bit.bor(
				fs.kFSEventStreamCreateFlagFileEvents,
				fs.kFSEventStreamCreateFlagNoDefer,
				fs.kFSEventStreamCreateFlagWatchRoot
			)
			local stream = lib.FSEventStreamCreate(
				nil,
				c_callback,
				nil,
				paths_array,
				fs.kFSEventStreamEventIdSinceNow,
				0.1,
				flags
			)

			if stream == nil then
				lib.CFRelease(paths_array)

				for i = 1, #path_cfs do
					lib.CFRelease(path_cfs[i])
				end

				return nil, "Failed to create FSEventStream"
			end

			setup_macos_watch_timer(lib)
			active_watches[c_callback] = {internal_callback, c_callback}
			lib.FSEventStreamScheduleWithRunLoop(stream, lib.CFRunLoopGetCurrent(), lib.kCFRunLoopDefaultMode)

			if not lib.FSEventStreamStart(stream) then
				lib.FSEventStreamInvalidate(stream)
				lib.FSEventStreamRelease(stream)
				lib.CFRelease(paths_array)

				for i = 1, #path_cfs do
					lib.CFRelease(path_cfs[i])
				end

				return nil, "Failed to start FSEventStream"
			end

			local remove_event = event.AddListener("Update", {}, function()
				if lib.CFRunLoopRunInMode then
					lib.CFRunLoopRunInMode(lib.kCFRunLoopDefaultMode, 0, true)
				end

				if #results > 0 then
					for i, res in ipairs(results) do
						callback(res.path, res.type)
						results[i] = nil
					end
				end
			end)
			return function()
				remove_event()
				lib.FSEventStreamStop(stream)
				lib.FSEventStreamInvalidate(stream)
				lib.FSEventStreamRelease(stream)
				lib.CFRelease(paths_array)

				for i = 1, #path_cfs do
					lib.CFRelease(path_cfs[i])
				end

				active_watches[c_callback] = nil
				c_callback:free()
			end
		end
	end
end

return fs
