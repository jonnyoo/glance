#ifndef BRIO_IR_ENGINE_H
#define BRIO_IR_ENGINE_H
#include <stddef.h>
typedef struct brio_ir_job brio_ir_job;
brio_ir_job *brio_ir_create(void);
void brio_ir_cancel(brio_ir_job *job);
/* Single use; returns heap-owned JSON. Capture never writes image files. */
char *brio_ir_snapshot(brio_ir_job *job, size_t *length);
void brio_ir_free_response(char *data, size_t length);
/* Only after capture has returned and no other thread can cancel. */
void brio_ir_destroy(brio_ir_job *job);
#endif
