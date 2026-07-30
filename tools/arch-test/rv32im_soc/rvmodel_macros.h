#ifndef RV32IM_SOC_RVMODEL_MACROS_H
#define RV32IM_SOC_RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION

#define RVMODEL_HALT_PASS \
  li x1, 0x600dface ;\
  li x2, 0x100      ;\
  sw x1, 0(x2)      ;\
1:                  ;\
  j 1b

#define RVMODEL_HALT_FAIL \
  li x1, 0xbad0fade ;\
  li x2, 0x100      ;\
  sw x1, 0(x2)      ;\
1:                  ;\
  j 1b

#define RVMODEL_IO_INIT(_R1, _R2, _R3)
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 100
#define RVMODEL_MAX_CYCLES_PER_TIMER_TICK 1

#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif
