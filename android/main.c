#include <android/log.h>
#include <android_native_app_glue.h>
#include <lauxlib.h>
#include <lualib.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *boot =
	"local file = io.open('args.txt', 'rb') "
	"arg = {[0] = 'glw'} "
	"if file then "
	"	for line in file:lines() do arg[#arg + 1] = line end "
	"	file:close() "
	"else "
	"	arg[1] = '--2d' "
	"end "
	"require('goluwa.main')";

static void *forward_to_logcat(void *arg)
{
	int fd = (int)(intptr_t)arg;
	char line[4096];
	size_t len = 0;

	for (;;) {
		ssize_t got = read(fd, line + len, sizeof(line) - 1 - len);

		if (got <= 0)
			break;

		len += (size_t)got;
		size_t start = 0;

		for (size_t i = 0; i < len; i++) {
			if (line[i] == '\n') {
				line[i] = 0;
				__android_log_write(ANDROID_LOG_INFO, "goluwa", line + start);
				start = i + 1;
			}
		}

		if (start == 0 && len == sizeof(line) - 1) {
			line[len] = 0;
			__android_log_write(ANDROID_LOG_INFO, "goluwa", line);
			len = 0;
		} else {
			memmove(line, line + start, len - start);
			len -= start;
		}
	}

	if (len > 0) {
		line[len] = 0;
		__android_log_write(ANDROID_LOG_INFO, "goluwa", line);
	}

	return NULL;
}

void android_main(struct android_app *app)
{
	int fds[2];
	pthread_t logger;
	int logging = pipe(fds) == 0;

	if (logging) {
		dup2(fds[1], 1);
		dup2(fds[1], 2);
		close(fds[1]);
		setvbuf(stdout, NULL, _IOLBF, 0);
		setvbuf(stderr, NULL, _IONBF, 0);
		pthread_create(&logger, NULL, forward_to_logcat, (void *)(intptr_t)fds[0]);
	}

	const char *root = app->activity->internalDataPath;
	char address[32];
	snprintf(address, sizeof(address), "%p", (void *)app);
	setenv("GOLUWA_ANDROID_APP", address, 1);
	setenv("HOME", root, 1);
	setenv("TMPDIR", root, 1);

	if (chdir(root) != 0)
		fprintf(stderr, "could not enter %s\n", root);

	lua_State *L = luaL_newstate();
	luaL_openlibs(L);

	if (luaL_dostring(L, boot) != 0)
		fprintf(stderr, "%s\n", lua_tostring(L, -1));

	fflush(stdout);

	if (logging) {
		close(1);
		close(2);
		pthread_join(logger, NULL);
	}

	exit(0);
}
