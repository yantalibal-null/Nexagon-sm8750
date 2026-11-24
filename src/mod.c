struct property {
    char *name;
    int length;
    void *value;
    struct property *next;
};

struct device_node;
struct platform_device;

extern int _printk(const char *fmt, ...);
extern struct device_node *of_find_node_opts_by_path(const char *path, const char **opts);
extern struct property *of_find_property(const struct device_node *np, const char *name, int *lenp);
extern struct platform_device *of_platform_device_create(struct device_node *np, const char *bus_id, void *parent);

static char new_status[] = "okay";

int __attribute__((section(".init.text"), used)) real_init(void)
{
    struct device_node *np = of_find_node_opts_by_path("/soc/remoteproc-cdsp@32300000", 0);
    if (!np) {
        _printk("\0013enable_cdsp: node not found\n");
        return -19;
    }

    int len = 0;
    struct property *prop = of_find_property(np, "status", &len);
    if (prop) {
        prop->value = new_status;
        prop->length = 5;
    }

    struct platform_device *pdev = of_platform_device_create(np, 0, 0);
    _printk("\0016enable_cdsp: of_platform_device_create -> %p\n", pdev);
    return pdev ? 0 : -5;
}

void __attribute__((section(".exit.text"), used)) real_exit(void)
{
    _printk("\0016enable_cdsp: unloaded\n");
}
