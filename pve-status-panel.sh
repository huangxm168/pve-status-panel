#!/usr/bin/env bash
# pve-status-panel —— 在 Proxmox VE 节点「概览」卡片显示 CPU 频率 / 温度·风扇 / NVMe·磁盘 SMART·IO
#
# 「取其精华去其糟粕」加固版（源自社区 KoolCore/Proxmox_VE_Status，去糟粕如下）：
#   · 不设 setuid（原脚本给 smartctl/iostat 加 setuid root，提权面且无必要——API 本以 root 运行）
#   · 不装内核驱动/不改软件源/不跑 apt（面板只读现有传感器；驱动是用户 sensor 配置，不越界）
#   · 标记块注入（BEGIN/END 注释包裹）替代原脚本晦涩的 sed，配 perl -c 语法校验 + 失败自动回滚
#   · APT DPkg::Post-Invoke 自愈：pve-manager/pve-manager 升级覆盖后自动重打，不再「升级即消失」
#   · 板级双线路：有可用 IPMI 走 ipmitool（服务器板），否则走 lm-sensors（消费级板，复用上游渲染）
#   · 采集与注入解耦 + 按需：常驻守护经 inotify 在被查看时才采样写 /run，后端只读回填——无污点、不碰设备、空闲零唤醒磁盘
#
# 子命令：apply（安装/重打） | restore（还原官方原版） | status（查看状态） | setup-sensors（消费级板风扇驱动） | set-interval（最小采样间隔）
set -o pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVEMGR_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
STATE_DIR="/usr/local/share/pve-status-panel"
RUN_DIR="/run/pve-status-panel"
COLLECTOR_BIN="/usr/local/bin/pve-status-panel-collect"
SERVICE="pve-status-panel-collect.service"
TIMER="pve-status-panel-collect.timer"    # 旧版单元名，仅用于升级时清理
TMPFILES_CONF="/etc/tmpfiles.d/pve-status-panel.conf"
POLL_FILE="$RUN_DIR/.poll"                 # 按需信号：后端每次被查看时写此文件，守护据此采集
INTERVAL_FILE="$STATE_DIR/interval"        # 最小采样间隔（秒），守护每次采集现读
SENSORS_CONF="/etc/modules-load.d/pve-status-panel-sensors.conf"
DEFAULT_INTERVAL=5    # 最小采样间隔（秒），可被 install.sh <秒> / set-interval <秒> 覆盖
MARK_BEGIN="pve-status-panel:BEGIN"
MARK_END="pve-status-panel:END"

log() { echo "[pve-status-panel] $*"; }

# 探测传感器数据源：有可用 IPMI 则 ipmi，否则 sensors；PSP_MODE 可强制覆盖
detect_mode() {
    if [ -n "${PSP_MODE:-}" ]; then echo "$PSP_MODE"; return; fi
    if [ -e /dev/ipmi0 ] && command -v ipmitool >/dev/null 2>&1 \
       && ipmitool sdr type Temperature >/dev/null 2>&1; then
        echo ipmi
    else
        echo sensors
    fi
}

# 识别 CPU 平台（sensors 模式下选温度适配器关键字）
detect_cpu_platform() {
    local cpu_platform
    cpu_platform="$(lscpu | grep 'Model name' | grep -E 'Intel|AMD')"
    case $cpu_platform in
        *Intel*) CPU="Intel"; cpu_keyword="coretemp-isa" ;;
        *AMD*)   CPU="AMD";   cpu_keyword="k10temp-pci-" ;;
        *)       CPU="Unknown"; cpu_keyword="__none__" ;;
    esac
}

# 生成注入载荷：产出 INFO_DISPLAY（前端 JS 渲染项）与 height2（卡片高度）。
# cpu_freq / nvme / hdd 渲染器复用上游；温度·风扇渲染器由本项目按 ipmi/sensors 覆盖（见下方 override）。
_build_payloads() {
    MODE="$(detect_mode)"
    detect_cpu_platform
    log "数据源模式: $MODE，CPU 平台: $CPU"

    # CPU 主频信息 Web UI
    cpu_freq_display=',
	{
	    itemId: '"'"'cpu-frequency'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'CPU主频'"'"'),
	    textField: '"'"'cpu_frequency'"'"',
	    renderer:function(value){
	        let output = '"'"''"'"';
	        let cpufreqs = value.matchAll(/^CPU MHz.*?(\d+\.\d+)\\n^CPU max MHz.*?(\d+)\.\d+\\n^CPU min MHz.*?(\d+)\.\d+\\n/gm);
              for (const cpufreq of cpufreqs) {
                  output += `实时: ${cpufreq[1]} MHz | 最低: ${cpufreq[3]} MHz | 最高: ${cpufreq[2]} MHz\\n`;
              }

	        let corefreqs = value.match(/^cpu MHz.*?(\d+\.\d+)/gm);
	        if (corefreqs.length > 0) {
	            for (i = 1;i < corefreqs.length;) {
	                for (const corefreq of corefreqs) {
	                    output += `线程 ${i++}: ${corefreq.match(/(?<=:\s+)(\d+\.\d+)/g)} MHz`;
	                    output += '"'"' | '"'"';
	                    if ((i-1) % 4 == 0){
	                        output = output.slice(0, -2);
	                        output += '"'"'\\n'"'"';
	                    }
	                }
	            }
	        } else { 
	            output += '"'"'('"'"';
	            output += `${corefreqs}`;
	            output += '"'"')'"'"';
	        }
	        return output.replace(/\\n/g, '"'"'<br>'"'"');
	    }
	}'


    # NVME 硬盘信息 API 及 Web UI
    if [ $(ls /dev/nvme? 2> /dev/null | wc -l) -gt 0 ]; then
        i="1"
        nvme_info_display=''
        for nvme_device in $(ls -1 /dev/nvme?); do
            nvme_code=${nvme_device##*/}
        nvme_info_display_tmp=',
	{
	    itemId: '"'"''$nvme_code'-status'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'NVMe硬盘 '$i''"'"'),
	    textField: '"'"''$nvme_code'_status'"'"',
	    renderer:function(value){
	        if (value.length > 0) {
	            value = value.replace(/Â/g, '"'"''"'"');
	            let data = [];
	            let nvmes = value.matchAll(/(^(?:Model|Total|Temperature:|Percentage|Data|Power|Unsafe|Integrity Errors|nvme)[\s\S]*)+/gm);
	            for (const nvme of nvmes) {
	                let nvmeNumber = 0;
	                data[nvmeNumber] = {
	                       Models: [],
						   Integrity_Errors: [],
	                       Capacitys: [],
	                       Temperatures: [],
	                       Useds: [],
	                       Reads: [],
	                       Writtens: [],
	                       Cycles: [],
	                       Hours: [],
	                       Shutdowns: [],
	                       States: [],
	                       r_awaits: [],
	                       w_awaits: [],
	                       utils: []
	                };

	                let Models = nvme[1].matchAll(/^Model Number: *([ \S]*)$/gm);
	                for (const Model of Models) {
	                    data[nvmeNumber]['"'"'Models'"'"'].push(Model[1]);
	                }

	                let Integrity_Errors = nvme[1].matchAll(/^Media and Data Integrity Errors: *([ \S]*)$/gm);
	                for (const Integrity_Error of Integrity_Errors) {
	                    data[nvmeNumber]['"'"'Integrity_Errors'"'"'].push(Integrity_Error[1]);
	                }

	                let Capacitys = nvme[1].matchAll(/^Total NVM Capacity:[^\[]*\[([ \S]*)\]$/gm);
	                for (const Capacity of Capacitys) {
	                    data[nvmeNumber]['"'"'Capacitys'"'"'].push(Capacity[1]);
	                }

	                let Temperatures = nvme[1].matchAll(/^Temperature: *([\d]*)[ \S]*$/gm);
	                for (const Temperature of Temperatures) {
	                    data[nvmeNumber]['"'"'Temperatures'"'"'].push(Temperature[1]);
	                }

	                let Useds = nvme[1].matchAll(/^Percentage Used: *([ \S]*)%$/gm);
	                for (const Used of Useds) {
	                    data[nvmeNumber]['"'"'Useds'"'"'].push(Used[1]);
	                }

	                let Reads = nvme[1].matchAll(/^Data Units Read:[^\[]*\[([ \S]*)\]$/gm);
	                for (const Read of Reads) {
	                    data[nvmeNumber]['"'"'Reads'"'"'].push(Read[1]);
	                }

	                let Writtens = nvme[1].matchAll(/^Data Units Written:[^\[]*\[([ \S]*)\]$/gm);
	                for (const Written of Writtens) {
	                    data[nvmeNumber]['"'"'Writtens'"'"'].push(Written[1]);
	                }

	                let Cycles = nvme[1].matchAll(/^Power Cycles: *([ \S]*)$/gm);
	                for (const Cycle of Cycles) {
	                    data[nvmeNumber]['"'"'Cycles'"'"'].push(Cycle[1]);
	                }

	                let Hours = nvme[1].matchAll(/^Power On Hours: *([ \S]*)$/gm);
	                for (const Hour of Hours) {
	                    data[nvmeNumber]['"'"'Hours'"'"'].push(Hour[1]);
	                }

	                let Shutdowns = nvme[1].matchAll(/^Unsafe Shutdowns: *([ \S]*)$/gm);
	                for (const Shutdown of Shutdowns) {
	                    data[nvmeNumber]['"'"'Shutdowns'"'"'].push(Shutdown[1]);
	                }

	                let States = nvme[1].matchAll(/^nvme\S+(( *\d+\.\d{2}){22})/gm);
	                for (const State of States) {
	                    data[nvmeNumber]['"'"'States'"'"'].push(State[1]);
	                    const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
	                    if (IO_array.length > 0) {
	                        data[nvmeNumber]['"'"'r_awaits'"'"'].push(IO_array[4]);
	                        data[nvmeNumber]['"'"'w_awaits'"'"'].push(IO_array[10]);
	                        data[nvmeNumber]['"'"'utils'"'"'].push(IO_array[21]);
	                    }
	                }

	                let output = '"'"''"'"';
	                for (const [i, nvme] of data.entries()) {
	                    if (nvme.Models.length > 0) {
	                        for (const nvmeModel of nvme.Models) {
	                            output += `${nvmeModel}`;
	                        }
	                    }

	                    if (nvme.Integrity_Errors.length > 0) {
	                        for (const nvmeIntegrity_Error of nvme.Integrity_Errors) {
	                            if (nvmeIntegrity_Error != 0) {
	                                output += ` (0E: ${nvmeIntegrity_Error}-故障！)`;
	                            }
								break
	                        }
	                    }

	                    if (nvme.Capacitys.length > 0) {
	                        output += '"'"' | '"'"';
	                        for (const nvmeCapacity of nvme.Capacitys) {
	                            output += `容量: ${nvmeCapacity.replace(/ |,/gm, '"'"''"'"')}`;
	                        }
	                    }

	                    if (nvme.Useds.length > 0) {
	                        output += '"'"' | '"'"';
	                        for (const nvmeUsed of nvme.Useds) {
				    output += `已用寿命: ${nvmeUsed}% `;
	                            output += `剩余寿命: ${100 - nvmeUsed}% `;
	                            if (nvme.Reads.length > 0) {
	                                output += '"'"'('"'"';
	                                for (const nvmeRead of nvme.Reads) {
	                                    output += `已读${nvmeRead.replace(/ |,/gm, '"'"''"'"')}`;
	                                    output += '"'"')'"'"';
	                                }
	                            }

	                            if (nvme.Writtens.length > 0) {
	                                output = output.slice(0, -1);
	                                output += '"'"', '"'"';
	                                for (const nvmeWritten of nvme.Writtens) {
	                                    output += `已写${nvmeWritten.replace(/ |,/gm, '"'"''"'"')}`;
	                                }
	                                output += '"'"')'"'"';
	                            }
	                        }
	                    }

	                    if (nvme.States.length <= 0) {
	                        if (nvme.Cycles.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const nvmeCycle of nvme.Cycles) {
	                                output += `通电: ${nvmeCycle.replace(/ |,/gm, '"'"''"'"')}次`;
	                            }

	                            if (nvme.Shutdowns.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const nvmeShutdown of nvme.Shutdowns) {
	                                    output += `非安全断电${nvmeShutdown.replace(/ |,/gm, '"'"''"'"')}次`;
	                                }
	                            }

	                            if (nvme.Hours.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const nvmeHour of nvme.Hours) {
	                                    output += `累计${nvmeHour.replace(/ |,/gm, '"'"''"'"')}小时`;
	                                }
	                            }
	                        }
	                    }

	                    if (nvme.Temperatures.length > 0) {
	                        output += '"'"' | '"'"';
	                        for (const nvmeTemperature of nvme.Temperatures) {
	                            output += `温度: ${nvmeTemperature}°C`;
	                        }
	                    }

	                    if (nvme.States.length > 0) {
	                        if (nvme.Cycles.length > 0) {
	                            output += '"'"'\\n'"'"';
	                            for (const nvmeCycle of nvme.Cycles) {
	                                output += `通电: ${nvmeCycle.replace(/ |,/gm, '"'"''"'"')}次`;
	                            }

	                            if (nvme.Shutdowns.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const nvmeShutdown of nvme.Shutdowns) {
	                                    output += `非安全断电${nvmeShutdown.replace(/ |,/gm, '"'"''"'"')}次`;
	                                }
	                            }

	                            if (nvme.Hours.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const nvmeHour of nvme.Hours) {
	                                    output += `累计${nvmeHour.replace(/ |,/gm, '"'"''"'"')}小时`;
	                                }
	                            }
	                        }

	                        output += '"'"' | '"'"';
	                        if (nvme.r_awaits.length > 0) {
	                            for (const nvme_r_await of nvme.r_awaits) {
	                                output += `I/O: 读延迟${nvme_r_await}ms`;
	                            }
	                        }

	                        if (nvme.w_awaits.length > 0) {
	                            output += '"'"', '"'"';
	                            for (const nvme_w_await of nvme.w_awaits) {
	                                output += `写延迟${nvme_w_await}ms`;
	                            }
	                        }

	                        if (nvme.utils.length > 0) {
	                            output += '"'"', '"'"';
	                            for (const nvme_util of nvme.utils) {
	                                output += `负载${nvme_util}%`;
	                            }
	                        }
	                    }
	                }
	                return output.replace(/\\n/g, '"'"'<br>'"'"');
	            }
	        } else { 
	            return `提示: 未安装硬盘或已直通硬盘控制器！`;
	        }
	    }
	}'
        nvme_info_display="$nvme_info_display$nvme_info_display_tmp"
        i=$((i + 1))
    done
fi

# 其他存储设备信息 API 及 Web UI
if [ $(ls /dev/sd? 2> /dev/null | wc -l) -gt 0 ]; then
    i="1"
    hdd_info_display=''
    for hdd_device in $(ls -1 /dev/sd?); do
        hdd_code=${hdd_device##*/}
    hdd_info_display_tmp=',
	{
	    itemId: '"'"''$hdd_code'-status'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'其他存储介质 '$i''"'"'),
	    textField: '"'"''$hdd_code'_status'"'"',
	    renderer:function(value){
	        if (value.length > 0) {
	            value = value.replace(/Â/g, '"'"''"'"');
	            let data = [];
	            let devices = value.matchAll(/^((?:Device|Model|User|[ ]{0,2}\d|sd)[\s\S]*)+/gm);
	            for (const device of devices) {
	                let deviceNumber = 0;
	                data[deviceNumber] = {
	                       Models: [],
	                       Capacitys: [],
	                       Temperatures: [],
	                       Cycles: [],
	                       Hours: [],
	                       Shutdowns: [],
	                       States: [],
	                       r_awaits: [],
	                       w_awaits: [],
	                       utils: []
	                };

	                if(device[1].indexOf("Family") !== -1){
	                    let Models = device[1].matchAll(/^Model Family: *([ \S]*?)\\n^Device Model: *([ \S]*?)$/gm);
	                    for (const Model of Models) {
	                        data[deviceNumber]['"'"'Models'"'"'].push(`${Model[1]} - ${Model[2]}`);
	                    }
	                } else {
	                    let Models = device[1].matchAll(/Model: *([ \S]*?)$/gm);
	                    for (const Model of Models) {
	                        data[deviceNumber]['"'"'Models'"'"'].push(Model[1]);
	                    }
	                }

	                let Capacitys = device[1].matchAll(/^User Capacity:[^\[]*\[([ \S]*)\]$/gm);
	                for (const Capacity of Capacitys) {
	                    data[deviceNumber]['"'"'Capacitys'"'"'].push(Capacity[1]);
	                }

	                let Temperatures = device[1].matchAll(/Temperature[ \S]*(?:\-|In_the_past) *?(\d+)[ \S]*$/gm);
	                for (const Temperature of Temperatures) {
	                    data[deviceNumber]['"'"'Temperatures'"'"'].push(Temperature[1]);
	                }

	                let Cycles = device[1].matchAll(/Cycle[ \S]*(?:\-|In_the_past) *?(\d+)[ \S]*$/gm);
	                for (const Cycle of Cycles) {
	                    data[deviceNumber]['"'"'Cycles'"'"'].push(Cycle[1]);
	                }

	                let Hours = device[1].matchAll(/Hours[ \S]*(?:\-|In_the_past) *?(\d+)[ \S]*$/gm);
	                for (const Hour of Hours) {
	                    data[deviceNumber]['"'"'Hours'"'"'].push(Hour[1]);
	                }

	                let Shutdowns = device[1].matchAll(/(?:Retract|Loss|POR_Recovery)[ \S]*(?:\-|In_the_past) *?(\d+)[ \S]*$/gm);
	                for (const Shutdown of Shutdowns) {
	                    data[deviceNumber]['"'"'Shutdowns'"'"'].push(Shutdown[1]);
	                }

	                let States = device[1].matchAll(/^sd\S+(( *\d+\.\d{2}){22})/gm);
	                for (const State of States) {
	                    data[deviceNumber]['"'"'States'"'"'].push(State[1]);
	                    const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
	                    if (IO_array.length > 0) {
	                        data[deviceNumber]['"'"'r_awaits'"'"'].push(IO_array[4]);
	                        data[deviceNumber]['"'"'w_awaits'"'"'].push(IO_array[10]);
	                        data[deviceNumber]['"'"'utils'"'"'].push(IO_array[21]);
	                    }
	                }

	                let output = '"'"''"'"';
	                for (const [i, device] of data.entries()) {
	                    if (device.Models.length > 0) {
	                        for (const deviceModel of device.Models) {
	                            output += `${deviceModel}`;
	                        }
	                    }

	                    if (device.Capacitys.length > 0) {
	                        if (device.Models.length > 0) {
	                            output += '"'"' | '"'"';
                          }
	                        for (const deviceCapacity of device.Capacitys) {
	                            output += `容量: ${deviceCapacity.replace(/ |,/gm, '"'"''"'"')}`;
	                        }
	                    }

	                    if (device.States.length <= 0) {
	                        if (device.Cycles.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const deviceCycle of device.Cycles) {
	                                output += `通电: ${deviceCycle.replace(/ |,/gm, '"'"''"'"')}次`;
	                            }

	                            if (device.Shutdowns.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const deviceShutdown of device.Shutdowns) {
	                                    output += `非安全断电${deviceShutdown.replace(/ |,/gm, '"'"''"'"')}次`;
	                                }
	                            }

	                            if (device.Hours.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const deviceHour of device.Hours) {
	                                    output += `累计${deviceHour.replace(/ |,/gm, '"'"''"'"')}小时`;
	                                }
	                            }
	                        }
	                    } else if (device.Cycles.length <= 0) {
	                        if (device.States.length > 0) {
	                            if (device.Models.length > 0 || device.Capacitys.length > 0) {
	                                output += '"'"' | '"'"';
	                            }

	                            if (device.r_awaits.length > 0) {
	                                for (const device_r_await of device.r_awaits) {
	                                    output += `I/O: 读延迟${device_r_await}ms`;
	                                }
	                            }

	                            if (device.w_awaits.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const device_w_await of device.w_awaits) {
	                                    output += `写延迟${device_w_await}ms`;
	                                }
	                            }

	                            if (device.utils.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const device_util of device.utils) {
	                                    output += `负载${device_util}%`;
	                                }
	                            }
	                        }
	                    }

	                    if (device.Temperatures.length > 0) {
	                        output += '"'"' | '"'"';
	                        for (const deviceTemperature of device.Temperatures) {
	                            output += `温度: ${deviceTemperature}°C`;
                                break
	                        }
	                    }

	                    if (device.States.length > 0) {
	                        if (device.Cycles.length > 0) {
	                            output += '"'"'\\n'"'"';
	                            for (const deviceCycle of device.Cycles) {
	                                output += `通电: ${deviceCycle.replace(/ |,/gm, '"'"''"'"')}次`;
	                            }

	                            if (device.Shutdowns.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const deviceShutdown of device.Shutdowns) {
	                                    output += `非安全断电${deviceShutdown.replace(/ |,/gm, '"'"''"'"')}次`;
	                                }
	                            }

	                            if (device.Hours.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const deviceHour of device.Hours) {
	                                    output += `累计${deviceHour.replace(/ |,/gm, '"'"''"'"')}小时`;
	                                }
	                            }

	                            if (device.Models.length > 0 || device.Capacitys.length > 0) {
	                                output += '"'"' | '"'"';
	                            }

	                            if (device.r_awaits.length > 0) {
	                                for (const device_r_await of device.r_awaits) {
	                                    output += `I/O: 读延迟${device_r_await}ms`;
	                                }
	                            }

	                            if (device.w_awaits.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const device_w_await of device.w_awaits) {
	                                    output += `写延迟${device_w_await}ms`;
	                                }
	                            }

	                            if (device.utils.length > 0) {
	                                output += '"'"', '"'"';
	                                for (const device_util of device.utils) {
	                                    output += `负载${device_util}%`;
	                                }
	                            }
	                        }
	                    }
	                }
	                return output.replace(/\\n/g, '"'"'<br>'"'"');
	            }
	        } else { 
	            return `⚠警告: 未安装存储设备或已直通存储设备控制器！`;
	        }
	    }
	}'
    hdd_info_display="$hdd_info_display$hdd_info_display_tmp"
    i=$((i + 1))
done
fi

    # ---- IPMI 模式覆盖：温度/风扇拆成「温度」「风扇」两行、值带单位（标签居左、值居右为 pmxInfoWidget 默认）。
    #      后端已改“读文件”，此处只覆盖前端 cpu_temp_display。sensors 模式沿用上游渲染器（暂不动，
    #      待本机（消费级主板）真机验证 sensors 读取后再统一渲染器）。----
    if [ "${MODE:-sensors}" = "ipmi" ]; then
        # 温度项读 cpu_temperatures（ipmitool Temperature）、风扇项读 cpu_fans（ipmitool Fan）
        read -r -d '' cpu_temp_display <<'PSP_IPMI_DISP' || true
,
	{
	    itemId: 'cpu-temperatures',
	    colspan: 2,
	    printBar: false,
	    title: gettext('温度'),
	    textField: 'cpu_temperatures',
	    renderer: function(value) {
	        if (!value) { return '-'; }
	        let a = [];
	        for (const line of value.split('\n')) {
	            let f = line.split('|');
	            if (f.length < 5) { continue; }
	            let m = f[4].trim().match(/^(\d+)\s*degrees/);
	            if (m) { a.push(f[0].trim().replace(/ Temp$/, '') + ': ' + m[1] + '°C'); }
	        }
	        return a.length ? a.join(' | ') : '-';
	    }
	},
	{
	    itemId: 'cpu-fans',
	    colspan: 2,
	    printBar: false,
	    title: gettext('风扇'),
	    textField: 'cpu_fans',
	    renderer: function(value) {
	        if (!value) { return '-'; }
	        let a = [];
	        for (const line of value.split('\n')) {
	            let f = line.split('|');
	            if (f.length < 5) { continue; }
	            let m = f[4].trim().match(/^(\d+)\s*RPM/);
	            if (m && m[1] !== '0') { a.push(f[0].trim() + ': ' + m[1] + 'RPM'); }
	        }
	        return a.length ? a.join(' | ') : '—';
	    }
	},
PSP_IPMI_DISP
    else
        # sensors（消费级板）：温度、风扇均读 cpu_temperatures（完整 sensors 输出）。
        # 温度：按芯片分组、每芯片取首个温度值、友好标签（k10temp/coretemp→CPU、amdgpu→GPU）、跳过 nvme（已有独立卡片）。
        # 值格式为「NAME: +51.2 C」（LC_ALL=C 无 ° 符号），故解析 " C" 结尾、输出时补 °C。风扇无数据显示 —。
        read -r -d '' cpu_temp_display <<'PSP_SENSORS_DISP' || true
,
	{
	    itemId: 'cpu-temperatures',
	    colspan: 2,
	    printBar: false,
	    title: gettext('温度'),
	    textField: 'cpu_temperatures',
	    renderer: function(value) {
	        if (!value) { return '-'; }
	        const map = { k10temp: 'CPU', coretemp: 'CPU', amdgpu: 'GPU' };
	        const prio = { CPU: 0, GPU: 1 };
	        let chip = '', out = [], seen = {};
	        for (const line of value.split('\n')) {
	            let h = line.match(/^(\S+)-(?:pci|isa|acpi|virtual|i2c|spi)-\S+$/);
	            if (h) { chip = h[1]; continue; }
	            if (!chip || chip === 'nvme') { continue; }
	            let t = line.match(/:\s*\+?([\d.]+)\s*C(?:\s|$)/);
	            if (t && !seen[chip]) {
	                seen[chip] = 1;
	                // Super I/O 芯片（Nuvoton nct6xxx / ITE it8xxx / winbond / fintek）首个温度即 SYSTIN，标为 MB（主板）
	                let label = map[chip] || (/^(nct6\d{3}|it8\d{3}|w836|f71)/.test(chip) ? 'MB' : chip);
	                out.push(label + ': ' + Math.round(parseFloat(t[1])) + '°C');
	            }
	        }
	        out.sort((a, b) => ((prio[a.split(':')[0]] ?? 2) - (prio[b.split(':')[0]] ?? 2)));
	        return out.length ? out.join(' | ') : '-';
	    }
	},
	{
	    itemId: 'cpu-fans',
	    colspan: 2,
	    printBar: false,
	    title: gettext('风扇'),
	    textField: 'cpu_temperatures',
	    renderer: function(value) {
	        if (!value) { return '—'; }
	        let out = [];
	        for (const line of value.split('\n')) {
	            let m = line.match(/^([^\s:][^:]*?):\s*(\d+)\s*RPM/);
	            if (m && m[2] !== '0') { out.push(m[1].trim() + ': ' + m[2] + 'RPM'); }
	        }
	        return out.length ? out.join(' | ') : '—';
	    }
	},
PSP_SENSORS_DISP
    fi
    # 组装前端注入（后端已改「读文件」，不再需要 INFO_API / 临时文件）
    INFO_DISPLAY="$cpu_freq_display$cpu_temp_display$nvme_info_display$hdd_info_display"

    # 卡片高度（绝对像素，含原生行 + 注入行）：按显示行数估算，不依赖 sensors；宁大勿小（多余只留白，偏小会裁切）。
    # CPU 主频网格约 4 线程/行 + 汇总；温度、风扇各 1 行；每块盘卡片约 2-3 行。
    local threads freq_lines nvme_n hdd_n
    threads="$(nproc 2>/dev/null || echo 4)"
    freq_lines=$(( (threads + 3) / 4 + 1 ))
    nvme_n=$(ls /dev/nvme? 2>/dev/null | wc -l)
    hdd_n=$(ls /dev/sd? 2>/dev/null | wc -l)
    height2=$(( 360 + (freq_lines + 2) * 20 + (nvme_n + hdd_n) * 55 + 30 ))
}

# 写出 perl 注入器（幂等 + 锚点定位；载荷从文件读入，避免插值）
_write_perl_inserter() {
    cat > "$1" <<'PERLEOF'
my ($target, $payload, $mode) = @ARGV;
local $/;
open my $pf, "<", $payload or die "payload open failed";
my $blk = <$pf>; close $pf;
open my $tf, "<", $target or die "target open failed";
my $c = <$tf>; close $tf;
exit 0 if $c =~ /pve-status-panel:BEGIN/;   # 幂等：已注入则不动
if ($mode eq "nodes") {
    $c =~ s/(\$res->\{pveversion\}\s*=\s*PVE::pvecfg::package\(\)\s*\.\s*"\/"\s*\.\s*PVE::pvecfg::version_text\(\);\n)/$1$blk/
        or die "nodes anchor not found";
} else {
    $c =~ s/(textField:\s*'pveversion',\s*\n\s*value:\s*'',\s*\n\s*\},)/$1\n$blk/
        or die "js anchor not found";
}
open my $of, ">", $target or die "target write failed";
print $of $c; close $of;
PERLEOF
}

# 目标文件“干净”（无我方标记）时快照当前版本原文件，供 restore 精确还原
_ensure_orig() {
    mkdir -p "$STATE_DIR"
    grep -q "$MARK_BEGIN" "$1" || cp -a "$1" "$STATE_DIR/$(basename "$1").orig"
}

# 调整概览卡片高度（restore 经 .orig 回退，故无需单独还原高度）
_bump_height() {
    sed -i "/widget.pveNodeStatus/,/},/ s/height: [0-9]\+/height: ${1}/" "$PVEMGR_JS"
}

# 生成采集守护脚本内容（全局 COLLECTOR）：常驻运行，把各硬件字段写入 $RUN_DIR/<field>。
# 与前端 textField 同名（cpu_frequency / cpu_temperatures / <dev>_status），供后端只读回填。
# 采集在 pvedaemon 之外常驻 => 无 perl -T 污点、且能访问 /dev/ipmi0 与 /dev/nvme*（守护进程内两者均受限）。
# 按需：启动预热一次后挂在 inotify 上等 $POLL_FILE 变化再采；节流控制「有人看时」的最小采样间隔。
_build_collector() {
    local dev code body

    # collect() 函数体：跑硬件命令写入各字段（每行前置 4 空格缩进，落在函数内）
    body="    { lscpu | grep MHz; cat /proc/cpuinfo | grep -i 'cpu MHz'; } 2>/dev/null | _w cpu_frequency
"
    if [ "${MODE:-sensors}" = "ipmi" ]; then
        body+="    ipmitool sdr type Temperature 2>/dev/null | _w cpu_temperatures
    ipmitool sdr type Fan 2>/dev/null | _w cpu_fans
"
    else
        body+="    sensors 2>/dev/null | _w cpu_temperatures
"
    fi
    # iostat 采一次，供各盘复用（避免每盘各跑一次 1s 采样）
    body+="    local _iostat=\"\$(iostat -d -x -k 1 1 2>/dev/null)\"
"
    for dev in $(ls -1 /dev/nvme? 2>/dev/null); do
        code="${dev##*/}"
        body+="    { smartctl -a ${dev} 2>/dev/null | grep -E 'Model Number|Total NVM Capacity|Temperature:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors'; echo \"\$_iostat\" | grep -E '^${code}'; } | _w ${code}_status
"
    done
    for dev in $(ls -1 /dev/sd? 2>/dev/null); do
        code="${dev##*/}"
        body+="    { smartctl -a ${dev} 2>/dev/null | grep -E 'Model|Capacity|Power_On_Hours|Power_Cycle_Count|Power-Off_Retract_Count|Unexpected_Power_Loss|Unexpect_Power_Loss_Ct|POR_Recovery|Temperature'; echo \"\$_iostat\" | grep -E '^${code}'; } | _w ${code}_status
"
    done

    COLLECTOR="#!/usr/bin/env bash
# pve-status-panel 采集守护（常驻）：预热采一次后，挂在 inotify 上等 .poll 变化再采。
export LC_ALL=C
D='${RUN_DIR}'
POLL='${POLL_FILE}'
INTERVAL_FILE='${INTERVAL_FILE}'
mkdir -p \"\$D\"
# 临时文件用隐藏名 + PID：后端 reader 跳过点开头文件、且并发采集不撞名；mv 原子替换
_w() { local t=\"\$D/.wtmp.\$1.\$\$\"; cat > \"\$t\" 2>/dev/null && mv -f \"\$t\" \"\$D/\$1\"; }

# 采集一次：把各硬件字段写入 \$D
collect() {
${body}}

# 节流：距上次采样不足 interval 秒则跳过（有人盯着看时避免每次轮询都猛跑 SMART、唤醒磁盘）
_last=0
throttle_ok() {
    local iv now
    iv=\"\$(cat \"\$INTERVAL_FILE\" 2>/dev/null || echo ${DEFAULT_INTERVAL})\"
    [[ \"\$iv\" =~ ^[0-9]+\$ ]] || iv=${DEFAULT_INTERVAL}
    now=\"\$(date +%s)\"
    (( now - _last < iv )) && return 1
    _last=\"\$now\"
    return 0
}

collect                                   # 启动即预热一次（重启后一开概览就有数据）
_last=\"\$(date +%s)\"

# 事件循环：优先 inotify 等 .poll 变化；无 inotifywait 则退化为轻量 mtime 轮询（每 2 秒）
if command -v inotifywait >/dev/null 2>&1; then
    while read -r _f; do
        [ \"\$_f\" = '.poll' ] || continue    # 只响应 .poll，忽略自身临时文件的 close_write 事件
        throttle_ok && collect
    done < <(inotifywait -m -q -e close_write --format '%f' \"\$D\" 2>/dev/null)
else
    _seen=0
    while :; do
        _m=\"\$(stat -c %Y \"\$POLL\" 2>/dev/null || echo 0)\"
        [ \"\$_m\" != \"\$_seen\" ] && { _seen=\"\$_m\"; throttle_ok && collect; }
        sleep 2
    done
fi
"
}

apply() {
    command -v pvesh >/dev/null 2>&1 || { log "非 PVE 环境，退出"; return 1; }
    if grep -q "$MARK_BEGIN" "$NODES_PM" && grep -q "$MARK_BEGIN" "$PVEMGR_JS"; then
        log "已是注入状态，跳过（幂等）"; return 0
    fi
    _build_payloads      # 前端 INFO_DISPLAY + 卡片高度 height2
    _build_collector     # 采集脚本 COLLECTOR

    local ins api_tmp js_tmp disp
    ins="$(mktemp)"; _write_perl_inserter "$ins"

    # ---- 部署采集守护 + 运行时单元 ----
    # pvedaemon 的 Web API 跑在 perl -T 污点模式、且其上下文看不到 /dev/ipmi0、/dev/nvme*，故不能在 status
    # 处理函数里直接跑 ipmitool/smartctl（反引号 → "Insecure dependency" 500；run_command → 设备打不开）。
    # 解耦：采集守护在普通 root 上下文常驻跑命令写 $RUN_DIR，后端只“读文件”回填——无污点、不碰设备、且更快。
    # （CLI pvesh 不走 -T 也不受设备限制，故此前用 pvesh 验证未能暴露，须用真实 HTTP API 验证。）
    printf '%s\n' "$COLLECTOR" > "$COLLECTOR_BIN"; chmod 0755 "$COLLECTOR_BIN"
    [ -f "$INTERVAL_FILE" ] || { mkdir -p "$STATE_DIR"; printf '%s\n' "$DEFAULT_INTERVAL" > "$INTERVAL_FILE"; }
    _write_units          # 部署 tmpfiles + 常驻守护 service 并启用

    # ---- 后端 Nodes.pm：注入“只读 $RUN_DIR 回填 $res”静态块（file_get_contents，-T 安全）+ perl -c 兜底 ----
    _ensure_orig "$NODES_PM"
    api_tmp="$(mktemp)"
    {
        printf '        # %s\n' "$MARK_BEGIN"
        cat <<'PSP_READER'
        {
            my $psp_dir = '/run/pve-status-panel';
            # 按需信号：记下「刚有人查看」，供采集守护经 inotify 触发采集。
            # 普通写（非原子）以可靠触发 close_write；eval 兜底，任何失败都不影响节点 API。
            eval {
                mkdir($psp_dir) unless -d $psp_dir;
                if (open(my $psp_pf, '>', "$psp_dir/.poll")) {
                    print $psp_pf time();
                    close($psp_pf);
                }
            };
            # 只读回填：采集守护已写入的硬件字段（跳过点开头文件，含 .poll 与 .wtmp.* 临时文件）
            if (opendir(my $psp_dh, $psp_dir)) {
                for my $psp_f (grep { !/^\./ && -f "$psp_dir/$_" } readdir($psp_dh)) {
                    $res->{$psp_f} = eval { PVE::Tools::file_get_contents("$psp_dir/$psp_f") } // '';
                }
                closedir($psp_dh);
            }
        }
PSP_READER
        printf '        # %s\n' "$MARK_END"
    } > "$api_tmp"
    cp -a "$NODES_PM" "$NODES_PM.psp-bak"
    perl "$ins" "$NODES_PM" "$api_tmp" nodes || { log "后端注入失败，回滚"; cp -a "$NODES_PM.psp-bak" "$NODES_PM"; rm -f "$NODES_PM.psp-bak" "$ins" "$api_tmp"; return 1; }
    if ! perl -c "$NODES_PM" >/dev/null 2>&1; then
        log "perl -c 校验未通过，回滚 Nodes.pm（不改动系统）"
        cp -a "$NODES_PM.psp-bak" "$NODES_PM"; rm -f "$NODES_PM.psp-bak" "$ins" "$api_tmp"; return 1
    fi
    rm -f "$NODES_PM.psp-bak"

    # ---- 前端 pvemanagerlib.js：去 INFO_DISPLAY 开头逗号后注入 ----
    _ensure_orig "$PVEMGR_JS"
    disp="$(printf '%s' "$INFO_DISPLAY" | sed '0,/^,$/{/^,$/d;}')"
    js_tmp="$(mktemp)"
    { printf '        // %s\n' "$MARK_BEGIN"; printf '%s\n' "$disp"; printf '        // %s\n' "$MARK_END"; } > "$js_tmp"
    cp -a "$PVEMGR_JS" "$PVEMGR_JS.psp-bak"
    if ! perl "$ins" "$PVEMGR_JS" "$js_tmp" js; then
        log "前端注入失败，回滚"; cp -a "$PVEMGR_JS.psp-bak" "$PVEMGR_JS"; rm -f "$PVEMGR_JS.psp-bak" "$ins" "$js_tmp"; return 1
    fi
    rm -f "$PVEMGR_JS.psp-bak"
    _bump_height "$height2"

    rm -f "$ins" "$api_tmp" "$js_tmp"
    systemctl restart "$SERVICE" 2>/dev/null || true   # 加载最新守护脚本并预热采一次
    systemctl restart pvedaemon pveproxy
    log "应用完成。浏览器 Ctrl+Shift+R 强刷即可看到概览卡片。"
}

_restore_file() {
    local f="$1" o="$STATE_DIR/$(basename "$1").orig"
    grep -q "$MARK_BEGIN" "$f" || return 0        # 无标记=已是原版
    if [ -f "$o" ]; then
        cp -a "$o" "$f"                            # 有标记则 .orig 必对应当前版本，精确还原（含高度）
    else
        sed -i "/${MARK_BEGIN}/,/${MARK_END}/d" "$f"   # 兜底：删标记块
    fi
}

restore() {
    _restore_file "$NODES_PM"
    _restore_file "$PVEMGR_JS"
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true   # 停常驻采集守护
    systemctl disable --now "$TIMER"   >/dev/null 2>&1 || true   # 兼容停旧版 timer
    rm -f "$COLLECTOR_BIN"
    rm -rf "$RUN_DIR"
    systemctl restart pvedaemon pveproxy 2>/dev/null
    log "已还原官方原版（采集守护已停）。浏览器 Ctrl+Shift+R 强刷。"
}

# 写运行时目录 tmpfiles + 常驻采集守护 service，并清理旧版周期 timer
_write_units() {
    # 保证 /run 目录重启后即存在（守护启动时 inotify 需目录先在）
    cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
EOF
    systemd-tmpfiles --create "$TMPFILES_CONF" >/dev/null 2>&1 || true

    cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=pve-status-panel on-demand hardware sensor collector
After=multi-user.target

[Service]
Type=simple
ExecStart=$COLLECTOR_BIN
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    # 清理旧版周期 timer（老用户升级平滑过渡）
    if [ -e "/etc/systemd/system/$TIMER" ]; then
        systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$TIMER"
    fi

    systemctl daemon-reload
    systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
}

# 设置「有人查看时的最小采样间隔」（秒）；无参则用默认。改后下次采集即生效、重启仍生效
set_interval() {
    [ "$(id -u)" = 0 ] || { log "需 root 运行"; return 1; }
    local iv="${1:-$DEFAULT_INTERVAL}"
    { [[ "$iv" =~ ^[0-9]+$ ]] && [ "$iv" -ge 2 ]; } || { log "用法: set-interval <秒>（整数，≥2）"; return 1; }
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$iv" > "$INTERVAL_FILE"    # 守护每次采集现读此文件，改后下次采集即生效，无需重启
    _write_units                               # 确保守护单元在位并运行
    log "最小采样间隔已设为 ${iv} 秒（有人查看概览时最快每 ${iv} 秒采一次）。"
}

# 可选：为消费级板加载 Super I/O 风扇/温度驱动（内核自带模块，不编译/不 dkms）。
# 逐一试探常见驱动，哪个让 sensors 冒出 fanN 行即命中并持久化到 modules-load.d；采集守护下次采集自动读到。
setup_sensors() {
    [ "$(id -u)" = 0 ] || { log "需 root 运行"; return 1; }
    command -v sensors >/dev/null 2>&1 || { log "未装 lm-sensors，请先 apt install lm-sensors"; return 1; }
    # 注意：用 here-string 而非「sensors | grep -q」——grep -q 命中即关管道，sensors 收 SIGPIPE 退非零，
    # 叠加脚本顶部 set -o pipefail 会把命中误判成失败。here-string 无管道即无此坑。
    local fan_re='^fan[0-9]+:.*RPM'
    if grep -qE "$fan_re" <<< "$(sensors 2>/dev/null)"; then
        log "当前 sensors 已能读到风扇，无需处理。"; grep -E "$fan_re" <<< "$(sensors 2>/dev/null)" | head; return 0
    fi
    log "当前读不到风扇，试探 Super I/O 驱动（内核自带，不编译）..."
    local m found=""
    for m in nct6775 nct6683 it87 w83627ehf f71882fg; do
        modinfo "$m" >/dev/null 2>&1 || continue          # 内核无此驱动则跳过
        modprobe "$m" 2>/dev/null || continue
        if grep -qE "$fan_re" <<< "$(sensors 2>/dev/null)"; then found="$m"; break; fi
        modprobe -r "$m" 2>/dev/null                       # 没帮上忙就卸掉，不留残留
    done
    if [ -n "$found" ]; then
        printf '%s\n' "$found" > "$SENSORS_CONF"           # 持久化：开机自动加载
        log "成功：驱动 $found 已加载并持久化（$SENSORS_CONF）。"
        log "风扇将在下次采集（有人查看概览时触发）自动出现于概览；浏览器 Ctrl+Shift+R 刷新即触发。"
        grep -E "$fan_re" <<< "$(sensors 2>/dev/null)" | head
    elif grep -qiE 'ACPI.*resource.*conflict|resource.*conflict.*(nct|it87|superio)' <<< "$(dmesg 2>/dev/null)"; then
        log "检测到 Super I/O 但其 I/O 端口被 ACPI 占用。需加内核参数后重启："
        log "  /etc/default/grub 的 GRUB_CMDLINE_LINUX_DEFAULT 追加 acpi_enforce_resources=lax → update-grub → reboot → 再跑本命令"
        return 1
    else
        log "未探测到受支持的 Super I/O 传感器芯片（可能内核过旧/芯片过新）。可更新内核或手动 sensors-detect 排查。"
        return 1
    fi
}

status() {
    echo "模式(自动探测)   : $(detect_mode)"
    echo "Nodes.pm 已注入   : $(grep -q "$MARK_BEGIN" "$NODES_PM" && echo yes || echo no)"
    echo "pvemanagerlib 注入: $(grep -q "$MARK_BEGIN" "$PVEMGR_JS" && echo yes || echo no)"
    echo "原文件快照(.orig) : $(ls "$STATE_DIR"/*.orig 2>/dev/null | wc -l) 个"
    echo "APT 自愈 hook     : $([ -f /etc/apt/apt.conf.d/99-pve-status-panel ] && echo installed || echo absent)"
    echo "采集守护(daemon)  : $(systemctl is-active "$SERVICE" 2>/dev/null || echo inactive)"
    echo "inotifywait      : $(command -v inotifywait >/dev/null 2>&1 && echo present || echo 'absent（守护退化为 2s 轮询）')"
    echo "最小采样间隔      : $(cat "$INTERVAL_FILE" 2>/dev/null || echo "$DEFAULT_INTERVAL") 秒"
    echo "最近被查看        : $([ -f "$POLL_FILE" ] && echo "$(( $(date +%s) - $(stat -c %Y "$POLL_FILE") )) 秒前" || echo 从未)"
    echo "采集数据          : $(ls "$RUN_DIR" 2>/dev/null | wc -l) 个字段 @ $RUN_DIR"
    echo "风扇数据          : $(grep -qsE '[1-9][0-9]* *RPM' "$RUN_DIR"/cpu_fans "$RUN_DIR"/cpu_temperatures && echo 有 || echo '无（消费级板可跑 setup-sensors 开启）')"
}

case "${1:-}" in
    apply)         apply ;;
    restore)       restore ;;
    status)        status ;;
    setup-sensors) setup_sensors ;;
    set-interval)  set_interval "${2:-}" ;;
    *) echo "用法: $0 {apply|restore|status|setup-sensors|set-interval <秒>}"; exit 2 ;;
esac
