cmake_minimum_required(VERSION 3.22)
project(voiceengine C)

# The JNI bridge for EngineService. libcrispasr.so is dlopen'ed at run time, not linked.
add_library(voiceengine SHARED engine_bridge.c stall.c)
target_compile_options(voiceengine PRIVATE -Wall -Wextra -Werror)
target_link_libraries(voiceengine dl log)
