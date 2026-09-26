## Compilation process steps

                           ┌────────────────────┐
                           │     source.c       │
                           └─────────┬──────────┘
                                     │
                                     │  Preprocessing
                                     │
                                     │  CPPFLAGS
                                     │
                                     │    -I include/path
                                     │    -D MACRO=value
                                     │    -U MACRO
                                     │
                                     ▼
                           ┌────────────────────┐
                           │ preprocessed .i    │
                           └─────────┬──────────┘
                                     │
                                     │  Compilation
                                     │
                                     │  CFLAGS
                                     │
                                     │    -std=c17
                                     │    -Wall -Wextra
                                     │    -O0 / -O2 / -O3
                                     │    -g
                                     │    -fsanitize=address
                                     │    -fstack-protector-strong
                                     │    -fPIE
                                     │
                                     ▼
                           ┌────────────────────┐
                           │ assembly .s        │
                           └─────────┬──────────┘
                                     │
                                     │  Assembly
                                     │
                                     │  ASFLAGS
                                     │
                                     │    assembler-specific flags
                                     │
                                     ▼
                           ┌────────────────────┐
                           │ object file .o     │
                           └─────────┬──────────┘
                                     │
                                     │
             ┌───────────────────────┼───────────────────────┐
             │                       │                       │
             ▼                       ▼                       ▼
      ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
      │ file1.o     │         │ file2.o     │         │ file3.o     │
      └──────┬──────┘         └──────┬──────┘         └──────┬──────┘
             │                       │                       │
             └───────────────────────┼───────────────────────┘
                                     │
                                     │  Linking
                                     │
                                     │  LDFLAGS, LDLIBS
                                     │
                                     │  LDFLAGS examples:
                                     │    -L/path/to/libs
                                     │    -Wl,-z,relro
                                     │    -Wl,-z,now
                                     │    -Wl,-Map=app.map
                                     │    -pie
                                     │
                                     │  LDLIBS examples:
                                     │    -lm
                                     │    -lpthread
                                     │    -ldl
                                     │    -lrt
                                     │
                                     ▼
                           ┌────────────────────┐
                           │ final executable   │
                           │ app                │
                           └────────────────────┘