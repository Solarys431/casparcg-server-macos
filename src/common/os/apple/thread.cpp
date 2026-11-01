#include "../thread.h"
#include "../../utf.h"
#include <pthread.h>
#include <pthread/qos.h>

namespace caspar {

void set_thread_name(const std::wstring& name) { pthread_setname_np(u8(name).c_str()); }

void set_thread_realtime_priority()
{
    // Not SCHED_FIFO as on Linux: on macOS a SCHED_FIFO priority of 2 is accepted but sits far below the
    // default of 31, so it would slow the thread down. The user-interactive QoS class is the highest one
    // for work that must not wait behind anything else.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

} // namespace caspar
