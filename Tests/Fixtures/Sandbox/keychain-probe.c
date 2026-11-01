#include <servers/bootstrap.h>
#include <mach/mach.h>
int main(void) {
    mach_port_t service = MACH_PORT_NULL;
    kern_return_t result = bootstrap_look_up(bootstrap_port, "com.apple.securityd.xpc", &service);
    if (result == KERN_SUCCESS) mach_port_deallocate(mach_task_self(), service);
    return result == KERN_SUCCESS ? 0 : 42;
}
