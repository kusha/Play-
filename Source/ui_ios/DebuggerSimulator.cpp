#include <dlfcn.h>
#include <sys/types.h>
#include <unistd.h>
#include <cstdlib>
#include <pthread.h>
#include <mach/mach.h>

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

#define PT_TRACE_ME 0
#define PT_SIGEXC 12
#define PT_DENY_ATTACH 31

typedef int (*ptrace_ptr_t)(int _request, pid_t _pid, caddr_t _addr, int _data);

static bool HasDebuggerAttached()
{
	int flags;
	return !csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof(flags)) && (flags & 0x10000000 /* CS_DEBUGGED */);
}

static void* ExceptionHandler(void* portPtr)
{
	mach_port_t port = *static_cast<mach_port_t*>(portPtr);
	mach_msg_header_t msg;
	for(;;)
	{
		kern_return_t kr = mach_msg(&msg, MACH_RCV_MSG, 0, sizeof(msg), port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
		if(kr != KERN_SUCCESS) break;
		_exit(1);
	}
	return nullptr;
}

void StartSimulateDebugger()
{
	auto ptrace_ptr = reinterpret_cast<ptrace_ptr_t>(dlsym(RTLD_SELF, "ptrace"));
	if(!ptrace_ptr) return;

	bool wasDebugged = HasDebuggerAttached();

	if(ptrace_ptr(PT_TRACE_ME, 0, NULL, 0) < 0) return;

	if(!wasDebugged)
	{
		ptrace_ptr(PT_SIGEXC, 0, NULL, 0);

		static mach_port_t exceptionPort = MACH_PORT_NULL;
		mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &exceptionPort);
		mach_port_insert_right(mach_task_self(), exceptionPort, exceptionPort, MACH_MSG_TYPE_MAKE_SEND);
		task_set_exception_ports(mach_task_self(), EXC_MASK_SOFTWARE, exceptionPort, EXCEPTION_DEFAULT, THREAD_STATE_NONE);

		pthread_t thread;
		pthread_create(&thread, nullptr, ExceptionHandler, &exceptionPort);
	}
	else
	{
		task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
	}
}

void StopSimulateDebugger()
{
	auto ptrace_ptr = reinterpret_cast<ptrace_ptr_t>(dlsym(RTLD_SELF, "ptrace"));
	if(ptrace_ptr)
	{
		ptrace_ptr(PT_DENY_ATTACH, 0, NULL, 0);
	}
}
