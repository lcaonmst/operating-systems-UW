#include <minix/drivers.h>
#include <minix/chardriver.h>
#include <stdio.h>
#include <stdlib.h>
#include <minix/ds.h>
#include <minix/ioctl.h>
#include <sys/ioc_hello_queue.h>
#include "hello_queue.h"

/*
 * Next value in modular arithmetic.
 */
#define NEXT(x, y) ((x) + 1 == (y)) ? 0 : (x) + 1

/*
 * Function prototypes for the hello_queue driver.
 */
static int hello_queue_open(devminor_t minor, int access, endpoint_t user_endpt);
static int hello_queue_close(devminor_t minor);
static ssize_t hello_queue_read(devminor_t minor, u64_t position, endpoint_t endpt,
                                cp_grant_id_t grant, size_t size, int flags, cdev_id_t id);
static ssize_t hello_queue_write(devminor_t minor, u64_t position, endpoint_t endpt,
                                 cp_grant_id_t grant, size_t size, int flags, cdev_id_t id);
static int hello_queue_ioctl(devminor_t minor, unsigned long request, endpoint_t endpt,
                             cp_grant_id_t grant, int flags, endpoint_t user_endpt, cdev_id_t id);

/* SEF functions and variables. */
static void sef_local_startup(void);
static int sef_cb_init(int type, sef_init_info_t *info);
static int sef_cb_lu_state_save(int);
static int lu_state_restore(void);

/* Entry points to the hello_queue driver. */
static struct chardriver hello_queue_tab =
{
        .cdr_open	= hello_queue_open,
        .cdr_close	= hello_queue_close,
        .cdr_read	= hello_queue_read,
        .cdr_write  = hello_queue_write,
        .cdr_ioctl  = hello_queue_ioctl
};

/*
 * Global queue for driver.
 */
typedef struct queue {
    size_t len;         // Number of bytes kept in queue.
    size_t front;       // Index of first byte in queue.
    size_t back;        // Index of last byte in queue.
    size_t buf_len;     // Number of bytes allocated in data.
    char *data;         // Queue data.
} queue_t;

static queue_t queue;

/*
 * Function fills the queue with multiply of 'xyz'.
 */
static void default_fill() {
    char c = 'x';
    size_t pos = queue.front;
    for (size_t i = 0; i < queue.buf_len; i++) {
        queue.data[pos] = c;
        c = (c == 'z') ? 'x' : c + 1;
        pos = NEXT(pos, queue.buf_len);
    }
}

/*
 * Function copy first buf_len bytes from queue to buf, respecting its order.
 * buf_len should be not greater than queue.len, otherwise undefined behavior occurs.
 * Function returns first unread index.
 */
static size_t cpy_from_queue(char *buf, size_t buf_len) {
    size_t new_front;
    if (queue.front + buf_len <= queue.buf_len) {
        strncpy(buf, queue.data + queue.front, buf_len);
        new_front = (queue.front + buf_len == queue.buf_len) ? 0 : queue.front + buf_len;
    }
    else {
        size_t fst_part = queue.buf_len - queue.front;
        strncpy(buf, queue.data + queue.front, fst_part);
        strncpy(buf + fst_part, queue.data, buf_len - fst_part);
        new_front = buf_len - fst_part;
    }
    return new_front;
}

/*
 * Function copy buf_len bytes from buf into the end of queue.
 * Queue should not have less free space than buf_len.
 */
static void cpy_to_queue(char *buf, size_t buf_len) {
    if (queue.back + buf_len <= queue.buf_len) {
        strncpy(queue.data + queue.back, buf, buf_len);
        queue.back = (queue.back + buf_len == queue.buf_len) ? 0 : queue.back + buf_len;
        queue.len += buf_len;
    }
    else {
        size_t fst_part = buf_len - queue.back;
        strncpy(queue.data + queue.back, buf, fst_part);
        strncpy(queue.data, buf + fst_part, buf_len - fst_part);
        queue.back = buf_len - fst_part;
        queue.len += buf_len;
    }
}

/*
 * Function decreases size of queue twice if buffer usage is not bigger than quarter and buffer length is greater than 1.
 * If malloc fails, function returns ENOMEM, otherwise OK.
 */
static int decrease_size() {
    if (queue.len * 4 <= queue.buf_len && queue.buf_len > 1) {
        size_t new_len = queue.buf_len / 2;
        char *new_data = (char *) malloc(new_len * sizeof(char));
        if (new_data == NULL) {
            printf("Unable to decrease buffer\n");
            return ENOMEM;
        }
        cpy_from_queue(new_data, queue.len);
        free(queue.data);
        queue.buf_len = new_len;
        queue.front = 0;
        queue.back = queue.len;
        queue.data = new_data;
    }
    return OK;
}

/*
 * Function increases size multiplying it by two until it will be not smaller than min_size.
 * If malloc fails, function returns ENOMEM, otherwise OK.
 */
static int increase_size(size_t min_size) {
    if (queue.buf_len < min_size) {
        size_t new_len = queue.buf_len;
        while (new_len < min_size) {
            new_len *= 2;
        }
        char *new_data = (char *) malloc(new_len * sizeof(char));
        if (new_data == NULL) {
            printf("Unable to increase buffer\n");
            return ENOMEM;
        }
        cpy_from_queue(new_data, queue.len);
        free(queue.data);
        queue.buf_len = new_len;
        queue.front = 0;
        queue.back = queue.len;
        queue.data = new_data;
    }
    return OK;
}

static int hello_queue_open(devminor_t UNUSED(minor), int UNUSED(access), endpoint_t UNUSED(user_endpt)) {
    printf("Device hello_queue is opened!\n");
    return OK;
}

static int hello_queue_close(devminor_t UNUSED(minor)) {
    printf("Hello_queue is closed!\n");
    return OK;
}

static ssize_t hello_queue_read(devminor_t UNUSED(minor), u64_t UNUSED(position), endpoint_t endpt,
                                cp_grant_id_t grant, size_t size, int UNUSED(flags), cdev_id_t UNUSED(id)) {
    if (queue.len == 0) {
        return 0;
    }
    size_t buf_len = MIN(size, queue.len);
    char *buf = (char *) malloc(buf_len * sizeof(char));
    if (buf == NULL) {
        printf("Unable to read from hello_queue.\n");
        return ENOMEM;
    }

    size_t new_front = cpy_from_queue(buf, buf_len);

    int r = sys_safecopyto(endpt, grant, 0, (vir_bytes) buf, buf_len);
    if (r != OK) {
        printf("Unable to read from hello_queue.\n");
        return r;
    }
    queue.front = new_front;
    queue.len -= buf_len;
    decrease_size();
    printf("Read %zu bytes from hello_queue!\n", buf_len);
    return buf_len;
}

static ssize_t hello_queue_write(devminor_t UNUSED(minor), u64_t UNUSED(position), endpoint_t endpt,
                                 cp_grant_id_t grant, size_t size, int UNUSED(flags), cdev_id_t UNUSED(id)) {
    char *buf = (char *) malloc(size * sizeof(char));
    if (buf == NULL) {
        printf("Unable to write to hello_queue 1\n");
        return ENOMEM;
    }
    int r = sys_safecopyfrom(endpt, grant, 0, (vir_bytes) buf, size);
    if (r != OK) {
        printf("Unable to write to hello_queue 2\n");
        return r;
    }
    r = increase_size(queue.len + size);
    if (r != OK) {
        printf("Unable to write to hello_queue 3\n");
        return r;
    }
    cpy_to_queue(buf, size);
    printf("Write %zu bytes to hello_queue\n", size);
    return size;
}

/*
 * Function handles HQIOCRES operation.
 * Returns OK if succeeded.
 */
static int res_handler() {
    if (queue.buf_len != DEVICE_SIZE) {
        char *new_data = (char *) malloc(DEVICE_SIZE * sizeof(char));
        if (new_data == NULL) {
            printf("Unable to change buffer\n");
            return ENOMEM;
        }
        free(queue.data);
        queue.data = new_data;
        queue.buf_len = DEVICE_SIZE;
    }
    queue.len = DEVICE_SIZE;
    queue.front = 0;
    queue.back = 0;
    default_fill();
    return OK;
}

/*
 * Function handles HQIOCSET operation.
 * Returns OK if succeeded.
 */
static int set_handler(char buf[MSG_SIZE]) {
    int r = increase_size(MSG_SIZE);
    if (r != OK) {
        return r;
    }
    if (MSG_SIZE >= queue.len) {
        queue.back = queue.front;
        queue.len = 0;
    }
    else {
        queue.back = (queue.back >= MSG_SIZE) ? queue.back - MSG_SIZE : queue.buf_len - MSG_SIZE + queue.back;
        queue.len -= MSG_SIZE;
    }
    cpy_to_queue(buf, MSG_SIZE);

    return OK;
}

/*
 * Function handles HQIOCXCH operation.
 * Returns OK if succeeded.
 */
static int xch_handler(char letters[2]) {
    if (letters[0] != letters[1]) {
        size_t pos = queue.front;
        for (size_t i = 0; i < queue.len; i++) {
            if (queue.data[pos] == letters[0]) {
                queue.data[pos] = letters[1];
            }
            pos = NEXT(pos, queue.buf_len);
        }
    }
    return OK;
}

/*
 * Function handles HQIOCDEL operation.
 * Returns OK if succeeded.
 */
static int del_handler() {
    size_t curr_pos = queue.front;
    size_t empty_pos = queue.front;
    size_t new_len = 0;
    u8_t counter = 0;
    for (size_t i = 0; i < queue.len; i++) {
        if (counter < 2) {
            queue.data[empty_pos] = queue.data[curr_pos];
            empty_pos = NEXT(empty_pos, queue.buf_len);
            new_len++;
        }
        curr_pos = NEXT(curr_pos, queue.buf_len);
        counter = NEXT(counter, 3);
    }
    queue.len = new_len;
    queue.back = empty_pos;
    return OK;
}

static int hello_queue_ioctl(devminor_t UNUSED(minor), unsigned long request, endpoint_t endpt,
                             cp_grant_id_t grant, int UNUSED(flags), endpoint_t UNUSED(user_endpt), cdev_id_t UNUSED(id)) {
    int r;
    char buf[MSG_SIZE];
    char letters[2];

    switch (request) {
        case HQIOCRES:
            r = res_handler();
            break;
        case HQIOCSET:
            r = sys_safecopyfrom(endpt, grant, 0, (vir_bytes) buf, MSG_SIZE * sizeof(char));
            if (r == OK) {
                r = set_handler(buf);
            }
            break;
        case HQIOCXCH:
            r = sys_safecopyfrom(endpt, grant, 0, (vir_bytes) letters, 2 * sizeof(char));
            if (r == OK) {
                r = xch_handler(letters);
            }
            break;
        case HQIOCDEL:
            r = del_handler();
            break;
    }
    return r;
}

static int sef_cb_lu_state_save(int UNUSED(state)) {
    /* Save the state. */

    ds_publish_u32("queue_len", queue.len, DSF_OVERWRITE);
    ds_publish_u32("queue_buf_len", queue.buf_len, DSF_OVERWRITE);
    ds_publish_u32("queue_front", queue.front, DSF_OVERWRITE);
    ds_publish_u32("queue_back", queue.back, DSF_OVERWRITE);
    ds_publish_mem("queue_data", queue.data, queue.buf_len, DSF_OVERWRITE);
    free(queue.data);

    return OK;
}

static int lu_state_restore() {
    /* Restore the state. */

    ds_retrieve_u32("queue_len", &queue.len);
    ds_delete_u32("queue_len");
    ds_retrieve_u32("queue_buf_len", &queue.buf_len);
    ds_delete_u32("queue_buf_len");
    ds_retrieve_u32("queue_front", &queue.front);
    ds_delete_u32("queue_front");
    ds_retrieve_u32("queue_back", &queue.back);
    ds_delete_u32("queue_back");
    queue.data = (char *) malloc(queue.buf_len * sizeof(char));
    if (queue.data == NULL) {
        return ENOMEM;
    }
    ds_retrieve_mem("queue_data", queue.data, &queue.buf_len);
    ds_delete_mem("queue_data");

    return OK;
}


static void sef_local_startup() {
    /* Register init callbacks. Use the same function for all event types. */
    sef_setcb_init_fresh(sef_cb_init);
    sef_setcb_init_lu(sef_cb_init);
    sef_setcb_init_restart(sef_cb_init);

    /* Register live update callbacks. */
    /* - Agree to update immediately when LU is requested in a valid state. */
    sef_setcb_lu_prepare(sef_cb_lu_prepare_always_ready);
    /* - Support live update starting from any standard state. */
    sef_setcb_lu_state_isvalid(sef_cb_lu_state_isvalid_standard);
    /* - Register a custom routine to save the state. */
    sef_setcb_lu_state_save(sef_cb_lu_state_save);

    /* Let SEF perform startup. */
    sef_startup();
}

static int sef_cb_init(int type, sef_init_info_t *UNUSED(info)) {
    /* Initialize the hello_queue driver. */
    int do_announce_driver = TRUE;

    switch(type) {
        case SEF_INIT_FRESH:
            queue.data = (char *) malloc(DEVICE_SIZE * sizeof(char));
            if (queue.data == NULL) {
                return ENOMEM;
            }
            queue.buf_len = DEVICE_SIZE;
            queue.len = DEVICE_SIZE;
            queue.front = 0;
            queue.back = 0;
            default_fill();
            break;

        case SEF_INIT_LU:
            /* Restore the state. */
            lu_state_restore();
            do_announce_driver = FALSE;
            printf("Hey, I'm a new version!\n");
            break;

        case SEF_INIT_RESTART:
            lu_state_restore();
            printf("Hey, I've just been restarted!\n");
            break;
    }

    /* Announce we are up when necessary. */
    if (do_announce_driver) {
        char driver_announce();
    }

    /* Initialization completed successfully. */
    return OK;
}

int main(void) {
    /* Perform initialization. */
    sef_local_startup();

    /* Run the main loop. */
    chardriver_task(&hello_queue_tab);
    free(queue.data);
    return OK;
}