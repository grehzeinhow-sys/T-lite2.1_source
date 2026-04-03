#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysinfo.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <mntent.h>
#include <time.h>
#include <dirent.h>
#include <pwd.h>
#include <utmpx.h>
#include <fcntl.h>
#include <ctype.h>

#define BUFFER_SIZE 4096
#define SLEEP_USEC  100000
#define MAX_CPUS    512
#define MAX_SECTIONS 20

typedef struct {
    char name[16];
    int enabled;
} Section;

Section sections[MAX_SECTIONS];
int section_count = 0;
int show_all = 1;

// Forward declarations
int should_display(const char *name);
void add_section(const char *name);
void parse_arguments(int argc, char *argv[]);
void print_system_info(void);
void print_time_info(void);
void print_cpu_info(void);
void print_memory_info(void);
void print_disk_info(void);
void print_network_info(void);
void print_gpu_info(void);
void print_logged_in_users(void);
void print_ssh_users(void);
void print_top_processes(void);
void print_sections_in_order(void);

// Optimized command execution
void exec_command_optimized(const char *cmd) {
    FILE *fp = popen(cmd, "r");
    if (!fp) return;

    char buf[256];
    while (fgets(buf, sizeof(buf), fp)) {
        fputs(buf, stdout);
    }
    pclose(fp);
}

// Parse CPU info with minimal overhead
void print_cpu_info(void) {
    if (!show_all && !should_display("cpu")) return;

    printf("\n========== CPU ==========\n");

    char buf[512];
    int num_cpus = 0;
    char model[128] = "Unknown";

    // Read cpuinfo once
    FILE *fp = fopen("/proc/cpuinfo", "r");
    if (fp) {
        while (fgets(buf, sizeof(buf), fp)) {
            if (strncmp(buf, "processor", 9) == 0) {
                num_cpus++;
            } else if (strncmp(buf, "model name", 10) == 0) {
                char *p = strchr(buf, ':');
                if (p) {
                    p += 2;
                    int len = strlen(p);
                    if (len > 0 && p[len-1] == '\n') p[len-1] = '\0';
                    strncpy(model, p, sizeof(model) - 1);
                    model[sizeof(model)-1] = '\0';
                }
            }
        }
        fclose(fp);
        printf("Model: %s\n", model);
        printf("Total cores: %d\n", num_cpus);
    }

    // Load average
    double loadavg[3];
    if (getloadavg(loadavg, 3) == 3) {
        printf("Load average: %.2f, %.2f, %.2f\n", loadavg[0], loadavg[1], loadavg[2]);
    }

    // Per-core CPU usage with single file read
    if (num_cpus > 0 && num_cpus <= MAX_CPUS) {
        unsigned long long user[MAX_CPUS], nice[MAX_CPUS], system[MAX_CPUS], idle[MAX_CPUS];
        unsigned long long iowait[MAX_CPUS], irq[MAX_CPUS], softirq[MAX_CPUS], steal[MAX_CPUS];

        fp = fopen("/proc/stat", "r");
        if (fp) {
            int idx = 0;
            while (fgets(buf, sizeof(buf), fp) && idx < num_cpus) {
                if (buf[0] == 'c' && buf[1] == 'p' && buf[2] == 'u' && buf[3] >= '0' && buf[3] <= '9') {
                    sscanf(buf, "cpu%d %llu %llu %llu %llu %llu %llu %llu %llu",
                           &idx, &user[idx], &nice[idx], &system[idx], &idle[idx],
                           &iowait[idx], &irq[idx], &softirq[idx], &steal[idx]);
                    idx++;
                }
            }
            fclose(fp);

            usleep(SLEEP_USEC);

            unsigned long long user2[MAX_CPUS], nice2[MAX_CPUS], system2[MAX_CPUS], idle2[MAX_CPUS];
            unsigned long long iowait2[MAX_CPUS], irq2[MAX_CPUS], softirq2[MAX_CPUS], steal2[MAX_CPUS];

            fp = fopen("/proc/stat", "r");
            if (fp) {
                idx = 0;
                while (fgets(buf, sizeof(buf), fp) && idx < num_cpus) {
                    if (buf[0] == 'c' && buf[1] == 'p' && buf[2] == 'u' && buf[3] >= '0' && buf[3] <= '9') {
                        sscanf(buf, "cpu%d %llu %llu %llu %llu %llu %llu %llu %llu",
                               &idx, &user2[idx], &nice2[idx], &system2[idx], &idle2[idx],
                               &iowait2[idx], &irq2[idx], &softirq2[idx], &steal2[idx]);
                        idx++;
                    }
                }
                fclose(fp);

                printf("\nPer-core usage:\n");
                double total_usage = 0;
                int active = 0;

                for (int i = 0; i < num_cpus; i++) {
                    unsigned long long total1 = user[i] + nice[i] + system[i] + idle[i] + iowait[i] + irq[i] + softirq[i] + steal[i];
                    unsigned long long total2 = user2[i] + nice2[i] + system2[i] + idle2[i] + iowait2[i] + irq2[i] + softirq2[i] + steal2[i];
                    unsigned long long idle1_all = idle[i] + iowait[i];
                    unsigned long long idle2_all = idle2[i] + iowait2[i];

                    unsigned long long delta_total = total2 - total1;
                    unsigned long long delta_idle = idle2_all - idle1_all;

                    if (delta_total > 0) {
                        double usage = 100.0 * (delta_total - delta_idle) / delta_total;
                        printf("  Core %2d: %5.1f%% [", i, usage);
                        int bars = (int)(usage / 2);
                        for (int j = 0; j < 50; j++) {
                            putchar(j < bars ? '#' : (j == bars ? '>' : ' '));
                        }
                        printf("]\n");
                        total_usage += usage;
                        active++;
                    }
                }

                if (active > 0) {
                    printf("\nAverage: %.2f%%\n", total_usage / active);
                }
            }
        }
    }
}

// Optimized memory info
void print_memory_info(void) {
    if (!show_all && !should_display("memory")) return;

    printf("\n========== MEMORY ==========\n");

    char buf[256];
    unsigned long long mem_total = 0, mem_free = 0, mem_avail = 0, swap_total = 0, swap_free = 0, cached = 0;

    FILE *fp = fopen("/proc/meminfo", "r");
    if (fp) {
        while (fgets(buf, sizeof(buf), fp)) {
            if (strncmp(buf, "MemTotal:", 9) == 0) {
                sscanf(buf, "MemTotal: %llu kB", &mem_total);
            } else if (strncmp(buf, "MemFree:", 8) == 0) {
                sscanf(buf, "MemFree: %llu kB", &mem_free);
            } else if (strncmp(buf, "MemAvailable:", 13) == 0) {
                sscanf(buf, "MemAvailable: %llu kB", &mem_avail);
            } else if (strncmp(buf, "SwapTotal:", 10) == 0) {
                sscanf(buf, "SwapTotal: %llu kB", &swap_total);
            } else if (strncmp(buf, "SwapFree:", 9) == 0) {
                sscanf(buf, "SwapFree: %llu kB", &swap_free);
            } else if (strncmp(buf, "Cached:", 7) == 0) {
                sscanf(buf, "Cached: %llu kB", &cached);
            }
        }
        fclose(fp);
    }

    if (mem_total > 0) {
        printf("RAM Total: %.2f GB, Free: %.2f GB, Avail: %.2f GB\n",
               mem_total / 1048576.0, mem_free / 1048576.0, mem_avail / 1048576.0);
        printf("Cached: %.2f GB\n", cached / 1048576.0);
        if (swap_total > 0) {
            printf("Swap Total: %.2f GB, Free: %.2f GB\n",
                   swap_total / 1048576.0, swap_free / 1048576.0);
        }
    }
}

// Optimized disk info
void print_disk_info(void) {
    if (!show_all && !should_display("disk")) return;

    printf("\n========== DISKS ==========\n");

    FILE *mtab = setmntent("/proc/mounts", "r");
    if (mtab) {
        struct mntent *mnt;
        printf("%-20s %-20s %8s %8s %8s\n", "Filesystem", "Mount point", "Size", "Used", "Avail");

        while ((mnt = getmntent(mtab))) {
            // Skip pseudo FS quickly
            const char *type = mnt->mnt_type;
            if (strcmp(type, "proc") == 0 || strcmp(type, "sysfs") == 0 ||
                strcmp(type, "devtmpfs") == 0 || strcmp(type, "tmpfs") == 0 ||
                strcmp(type, "cgroup2") == 0) {
                continue;
                }

                struct statvfs st;
            if (statvfs(mnt->mnt_dir, &st) == 0) {
                unsigned long long total = (unsigned long long)st.f_blocks * st.f_frsize;
                unsigned long long free = (unsigned long long)st.f_bfree * st.f_frsize;
                unsigned long long used = total - free;

                char size_str[10], used_str[10], avail_str[10];
                if (total >= 1073741824) {
                    snprintf(size_str, sizeof(size_str), "%.1fG", total / 1073741824.0);
                    snprintf(used_str, sizeof(used_str), "%.1fG", used / 1073741824.0);
                    snprintf(avail_str, sizeof(avail_str), "%.1fG", free / 1073741824.0);
                } else {
                    snprintf(size_str, sizeof(size_str), "%.0fM", total / 1048576.0);
                    snprintf(used_str, sizeof(used_str), "%.0fM", used / 1048576.0);
                    snprintf(avail_str, sizeof(avail_str), "%.0fM", free / 1048576.0);
                }

                printf("%-20s %-20s %8s %8s %8s\n", mnt->mnt_fsname, mnt->mnt_dir, size_str, used_str, avail_str);
            }
        }
        endmntent(mtab);
    }
}

// Network info
void print_network_info(void) {
    if (!show_all && !should_display("network")) return;

    printf("\n========== NETWORK ==========\n");

    char buf[512];
    FILE *fp = fopen("/proc/net/dev", "r");
    if (fp) {
        fgets(buf, sizeof(buf), fp); // Skip header
        fgets(buf, sizeof(buf), fp); // Skip header

        printf("%-12s %12s %12s %12s %12s\n", "Interface", "RX bytes", "RX errs", "TX bytes", "TX errs");

        while (fgets(buf, sizeof(buf), fp)) {
            char iface[32] = {0};
            unsigned long long rx_bytes, rx_errs, tx_bytes, tx_errs;

            // Parse line
            char *colon = strchr(buf, ':');
            if (colon) {
                int len = colon - buf;
                if (len > 0 && len < 31) {
                    strncpy(iface, buf, len);
                    iface[len] = '\0';

                    // Trim spaces
                    char *p = iface;
                    while (*p == ' ') p++;
                    if (p != iface) {
                        memmove(iface, p, strlen(p) + 1);
                    }

                    if (strcmp(iface, "lo") != 0) {
                        unsigned long long dummy;
                        sscanf(colon + 1, "%llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                               &rx_bytes, &dummy, &rx_errs, &dummy, &dummy, &dummy, &dummy, &dummy,
                               &tx_bytes, &dummy, &tx_errs);
                        printf("%-12s %12llu %12llu %12llu %12llu\n", iface, rx_bytes, rx_errs, tx_bytes, tx_errs);
                    }
                }
            }
        }
        fclose(fp);
    }
}

// GPU info
void print_gpu_info(void) {
    if (!show_all && !should_display("gpu")) return;

    printf("\n========== GPU ==========\n");

    if (access("/usr/bin/nvidia-smi", X_OK) == 0) {
        exec_command_optimized("nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null");
    } else {
        exec_command_optimized("lspci | grep -i 'vga\\|3d' | head -1");
    }
}

// Users
void print_logged_in_users(void) {
    if (!show_all && !should_display("users")) return;

    printf("\n========== LOGGED IN USERS ==========\n");

    setutxent();
    struct utmpx *u;
    int found = 0;

    printf("%-12s %-8s %-16s %s\n", "USER", "TERMINAL", "LOGIN TIME", "FROM");

    while ((u = getutxent())) {
        if (u->ut_type == USER_PROCESS) {
            found = 1;
            char time_str[20];
            time_t login_time = u->ut_tv.tv_sec;
            struct tm *tm_info = localtime(&login_time);
            strftime(time_str, sizeof(time_str), "%m-%d %H:%M", tm_info);

            printf("%-12s %-8s %-16s %s\n", u->ut_user, u->ut_line, time_str, u->ut_host);
        }
    }
    endutxent();

    if (!found) printf("No users logged in\n");
}

// SSH users
void print_ssh_users(void) {
    if (!show_all && !should_display("ssh")) return;

    printf("\n========== SSH CONNECTIONS ==========\n");
    exec_command_optimized("ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | tail -n +2 | awk '{print $4\" -> \"$5}'");
}

// Top processes
void print_top_processes(void) {
    if (!show_all && !should_display("processes")) return;

    printf("\n========== TOP PROCESSES ==========\n");
    printf("CPU:\n");
    exec_command_optimized("ps axo pid,comm,%cpu --sort=-%cpu 2>/dev/null | head -6");
    printf("\nMEM:\n");
    exec_command_optimized("ps axo pid,comm,%mem --sort=-%mem 2>/dev/null | head -6");
}

// System info
void print_system_info(void) {
    if (!show_all && !should_display("system")) return;

    printf("\n========== SYSTEM ==========\n");

    struct utsname uts;
    if (uname(&uts) == 0) {
        printf("%s %s %s\n", uts.sysname, uts.release, uts.machine);
    }

    char hostname[64];
    if (gethostname(hostname, sizeof(hostname)) == 0) {
        printf("Host: %s\n", hostname);
    }
}

// Time info
void print_time_info(void) {
    if (!show_all && !should_display("time")) return;

    printf("\n========== TIME ==========\n");

    time_t now = time(NULL);
    struct tm *tm;

    tm = localtime(&now);
    printf("Local: %04d-%02d-%02d %02d:%02d:%02d\n",
           tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
           tm->tm_hour, tm->tm_min, tm->tm_sec);

    tm = gmtime(&now);
    printf("UTC:   %04d-%02d-%02d %02d:%02d:%02d\n",
           tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
           tm->tm_hour, tm->tm_min, tm->tm_sec);

    struct sysinfo info;
    if (sysinfo(&info) == 0) {
        int days = info.uptime / 86400;
        int hours = (info.uptime % 86400) / 3600;
        int mins = (info.uptime % 3600) / 60;
        printf("Uptime: %dd %02dh %02dm\n", days, hours, mins);

        time_t boot = now - info.uptime;
        tm = localtime(&boot);
        printf("Boot:   %04d-%02d-%02d %02d:%02d:%02d\n",
               tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
               tm->tm_hour, tm->tm_min, tm->tm_sec);
    }
}

// Helper functions
void add_section(const char *name) {
    if (section_count >= MAX_SECTIONS) return;
    for (int i = 0; i < section_count; i++)
        if (strcmp(sections[i].name, name) == 0) return;

        strncpy(sections[section_count].name, name, 15);
    sections[section_count].name[15] = '\0';
    sections[section_count].enabled = 1;
    section_count++;
}

int should_display(const char *name) {
    if (show_all) return 1;
    for (int i = 0; i < section_count; i++)
        if (strcmp(sections[i].name, name) == 0) return 1;
        return 0;
}

void parse_arguments(int argc, char *argv[]) {
    if (argc < 2) {
        show_all = 1;
        return;
    }

    show_all = 0;

    for (int i = 1; i < argc; i++) {
        char *arg = argv[i];
        char *token = strtok(arg, ",");
        while (token) {
            if (strcmp(token, "system") == 0) add_section("system");
            else if (strcmp(token, "cpu") == 0) add_section("cpu");
            else if (strcmp(token, "memory") == 0 || strcmp(token, "mem") == 0) add_section("memory");
            else if (strcmp(token, "disk") == 0) add_section("disk");
            else if (strcmp(token, "network") == 0 || strcmp(token, "net") == 0) add_section("network");
            else if (strcmp(token, "gpu") == 0) add_section("gpu");
            else if (strcmp(token, "users") == 0) add_section("users");
            else if (strcmp(token, "ssh") == 0) add_section("ssh");
            else if (strcmp(token, "processes") == 0 || strcmp(token, "proc") == 0) add_section("processes");
            else if (strcmp(token, "time") == 0) add_section("time");
            else if (strcmp(token, "all") == 0) show_all = 1;
            token = strtok(NULL, ",");
        }
    }

    if (section_count == 0 && !show_all) show_all = 1;
}

void print_help(void) {
    printf("BIG BROTHER - System Resource Monitor\n");
    printf("Usage: ./bigbrother [sections...]\n");
    printf("Sections: system, cpu, memory, disk, network, gpu, users, ssh, processes, time\n");
    printf("Examples:\n");
    printf("  ./bigbrother cpu memory time\n");
    printf("  ./bigbrother disk network\n");
    printf("  ./bigbrother              # Show all\n");
}

void print_sections_in_order(void) {
    if (show_all) {
        print_system_info();
        print_time_info();
        print_cpu_info();
        print_memory_info();
        print_disk_info();
        print_network_info();
        print_gpu_info();
        print_logged_in_users();
        print_ssh_users();
        print_top_processes();
    } else {
        for (int i = 0; i < section_count; i++) {
            if (strcmp(sections[i].name, "system") == 0) print_system_info();
            else if (strcmp(sections[i].name, "time") == 0) print_time_info();
            else if (strcmp(sections[i].name, "cpu") == 0) print_cpu_info();
            else if (strcmp(sections[i].name, "memory") == 0) print_memory_info();
            else if (strcmp(sections[i].name, "disk") == 0) print_disk_info();
            else if (strcmp(sections[i].name, "network") == 0) print_network_info();
            else if (strcmp(sections[i].name, "gpu") == 0) print_gpu_info();
            else if (strcmp(sections[i].name, "users") == 0) print_logged_in_users();
            else if (strcmp(sections[i].name, "ssh") == 0) print_ssh_users();
            else if (strcmp(sections[i].name, "processes") == 0) print_top_processes();
        }
    }
}

int main(int argc, char *argv[]) {
    if (argc >= 2 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        print_help();
        return 0;
    }

    parse_arguments(argc, argv);

    printf("=== BIG BROTHER ===\n");

    print_sections_in_order();

    printf("\n=== DONE ===\n");
    return 0;
}
