#!/usr/bin/env bash
# pve-status-panel —— 在 Proxmox VE 节点「概览」卡片显示 CPU 频率 / 温度·风扇 / NVMe·磁盘 SMART·IO
#
# 「取其精华去其糟粕」加固版（源自社区 KoolCore/Proxmox_VE_Status，去糟粕如下）：
#   · 不设 setuid（原脚本给 smartctl/iostat 加 setuid root，提权面且无必要——API 本以 root 运行）
#   · 不装内核驱动/不改软件源/不跑 apt（面板只读现有传感器；驱动是用户 sensor 配置，不越界）
#   · 标记块注入（BEGIN/END 注释包裹）替代原脚本晦涩的 sed，配 perl -c 语法校验 + 失败自动回滚
#   · APT DPkg::Post-Invoke 自愈：pve-manager/pve-manager 升级覆盖后自动重打，不再「升级即消失」
#   · 板级双线路：有可用 IPMI 走 ipmitool（服务器板），否则走 lm-sensors（消费级板，复用上游渲染）
#
# 子命令：apply（安装/重打） | restore（还原官方原版） | status（查看状态）
set -o pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVEMGR_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
STATE_DIR="/usr/local/share/pve-status-panel"
RUN_DIR="/run/pve-status-panel"
COLLECTOR_BIN="/usr/local/bin/pve-status-panel-collect"
TIMER="pve-status-panel-collect.timer"
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

# 生成注入载荷：产出 INFO_API（后端 Perl）/ INFO_DISPLAY（前端 JS）/ height2（卡片高度）
# 下面 cpu_freq / cpu_temp(sensors) / nvme / hdd 渲染逻辑复用上游「精华」，原样保留
_build_payloads() {
    MODE="$(detect_mode)"
    detect_cpu_platform
    log "数据源模式: $MODE，CPU 平台: $CPU"
    cpu_info_api='		
	my $cpufreqs = `lscpu | grep MHz`;
	my $corefreqs = `cat /proc/cpuinfo | grep -i  "cpu MHz"`;
	$res->{cpu_frequency} = $cpufreqs . $corefreqs;

    # 获取所有温度传感器数据,包括网卡温度
    $res->{cpu_temperatures} = `sensors 2>/dev/null`;
		'

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

    # CPU 温度信息 Web UI (保持原有的Intel和AMD特定代码)
    if [ $CPU = "Intel" ]; then
        cpu_temp_display='
	{
	    itemId: '"'"'cpu-temperatures'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'CPU温度'"'"'),
	    textField: '"'"'cpu_temperatures'"'"',
	    renderer: function(value) {
	        value = value.replace(/Â/g, '"'"''"'"');
	        let data = [];
	        let cpus = value.matchAll(/^coretemp-isa-(\d{4})$\\n.*?\\n((?:Package|Core)[\s\S]*?^\\n)+/gm);
	        for (const cpu of cpus) {
	            let cpuNumber = parseInt(cpu[1], 10);
	            data[cpuNumber] = {
	                   packages: [],
	                   cores: []
	            };

	            let packages = cpu[2].matchAll(/^Package id \d+:\s*\+([^°]+).*$/gm);
	            for (const package of packages) {
	                data[cpuNumber]['"'"'packages'"'"'].push(package[1]);
	            }

	            let cores = cpu[2].matchAll(/^Core \d+:\s*\+([^°]+).*$/gm);
	            for (const core of cores) {
	                data[cpuNumber]['"'"'cores'"'"'].push(core[1]);
	            }
	        }

	        let output = '"'"''"'"';
	        for (const [i, cpu] of data.entries()) {
	            if (cpu.packages.length > 0) {
	                for (const packageTemp of cpu.packages) {
	                    output += `CPU ${i+1}: ${packageTemp}°C `;
	                }
	            }

	            if (cpu.cores.length > 0 && cpu.cores.length <= 4) {
	                output += '"'"'('"'"';
	                for (j = 1;j < cpu.cores.length;) {
	                    for (const coreTemp of cpu.cores) {
	                        output += `核心 ${j++}: ${coreTemp}°C, `;
	                    }
	                }
	                output = output.slice(0, -2);
	                output += '"'"')'"'"';
	            }

	            let acpitzs = value.matchAll(/^acpitz-acpi-(\d*)$\\n.*?\\n((?:temp)[\s\S]*?^\\n)+/gm);
	            for (const acpitz of acpitzs) {
	                let acpitzNumber = parseInt(acpitz[1], 10);
	                data[acpitzNumber] = {
	                       acpisensors: []
	                };

	                let acpisensors = acpitz[2].matchAll(/^temp\d+:\s*\+([^°]+).*$/gm);
	                for (const acpisensor of acpisensors) {
	                    data[acpitzNumber]['"'"'acpisensors'"'"'].push(acpisensor[1]);
	                }

	                for (const [k, acpitz] of data.entries()) {
	                    if (acpitz.acpisensors.length > 0) {
	                        output += '"'"' | 主板: '"'"';
	                        for (const acpiTemp of acpitz.acpisensors) {
	                            output += `${acpiTemp}°C, `;
	                        }
	                        output = output.slice(0, -2);
	                    }
	                }
	            }

	            let FunStates = value.matchAll(/^[a-zA-z]{2,3}\d{4}-isa-(\w{4})$\\n((?![ \S]+: *\d+ +RPM)[ \S]*?\\n)*((?:[ \S]+: *\d+ RPM)[\s\S]*?^\\n)+/gm);
	            for (const FunState of FunStates) {
	                let FanNumber = 0;
	                data[FanNumber] = {
	                    rotationals: [],
	                    cpufans: [],
	                    pumpfans: [],
	                    systemfans: []
	                };

	                let rotationals = FunState[3].match(/^([ \S]+: *[0-9]\d* +RPM)[ \S]*?$/gm);
	                for (const rotational of rotationals) {
	                    if (rotational.toLowerCase().indexOf("pump") !== -1 || rotational.toLowerCase().indexOf("opt") !== -1){
	                        let pumpfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const pumpfan of pumpfans) {
	                            data[FanNumber]['"'"'pumpfans'"'"'].push(pumpfan[1]);
	                        }
	                    } else if (rotational.toLowerCase().indexOf("cpu") !== -1){
	                        let cpufans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const cpufan of cpufans) {
	                            data[FanNumber]['"'"'cpufans'"'"'].push(cpufan[1]);
	                        }
	                    } else {
	                        let systemfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const systemfan of systemfans) {
	                            data[FanNumber]['"'"'systemfans'"'"'].push(systemfan[1]);
	                        }
	                    }
	                }

	                for (const [j, FunState] of data.entries()) {
	                    if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0 || FunState.systemfans.length > 0) {
	                        output += '"'"' | 风扇: '"'"';
	                        if (FunState.cpufans.length > 0) {
	                            output += '"'"'CPU-'"'"';
	                            for (const cpufan_value of FunState.cpufans) {
	                                output += `${cpufan_value}转/分钟, `;
	                            }
	                        }

	                        if (FunState.pumpfans.length > 0) {
	                            output += '"'"'水冷-'"'"';
	                            for (const pumpfan_value of FunState.pumpfans) {
	                                output += `${pumpfan_value}转/分钟, `;
	                            }
	                        }

	                        if (FunState.systemfans.length > 0) {
	                            if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0) {
	                                output += '"'"'系统-'"'"';
	                            }
	                            for (const systemfan_value of FunState.systemfans) {
	                                output += `${systemfan_value}转/分钟, `;
	                            }
	                        }
	                        output = output.slice(0, -2);
	                    } else if (FunState.cpufans.length == 0 && FunState.pumpfans.length == 0 && FunState.systemfans.length == 0) {
	                        output += '"'"' | 风扇: 停转'"'"';
	                    }
	                }
	            }

	            if (cpu.cores.length > 4) {
	                output += '"'"'\\n'"'"';
	                for (j = 1;j < cpu.cores.length;) {
	                    for (const coreTemp of cpu.cores) {
	                        output += `核心 ${j++}: ${coreTemp}°C`;
	                        output += '"'"' | '"'"';
	                        if ((j-1) % 4 == 0){
	                            output = output.slice(0, -2);
	                            output += '"'"'\\n'"'"';
	                        }
	                    }
	                }
	                output = output.slice(0, -2);
	            }
	        }

	        return output.replace(/\\n/g, '"'"'<br>'"'"');
	    }
	}'
    elif [ $CPU = "AMD" ]; then
        cpu_temp_display=',
	{
	    itemId: '"'"'cpu-temperatures'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'CPU温度'"'"'),
	    textField: '"'"'cpu_temperatures'"'"',
	    renderer: function(value) {
	        value = value.replace(/Â/g, '"'"''"'"');
	        let data = [];
	        let cpus = value.matchAll(/^k10temp-pci-(\w{4})$\\n.*?\\n((?:Tctl)[\s\S]*?^\\n)+/gm);
	        for (const cpu of cpus) {
	            let cpuNumber = 0;
	            data[cpuNumber] = {
	                   packages: []
	            };

	            let packages = cpu[2].matchAll(/^Tctl:\s*\+([^°]+).*$/gm);
	            for (const package of packages) {
	                data[cpuNumber]['"'"'packages'"'"'].push(package[1]);
	            }
	        }

	        let output = '"'"''"'"';
	        for (const [i, cpu] of data.entries()) {
	            if (cpu.packages.length > 0) {
	                for (const packageTemp of cpu.packages) {
	                    output += `CPU ${i+1}: ${packageTemp}°C `;
	                }
	            }

	            let gpus = value.matchAll(/^amdgpu-pci-(\d*)$\\n((?!edge:)[ \S]*?\\n)*((?:edge)[\s\S]*?^\\n)+/gm);
	            for (const gpu of gpus) {
	                let gpuNumber = 0;
	                data[gpuNumber] = {
	                       edges: []
	                };

	                let edges = gpu[3].matchAll(/^edge:\s*\+([^°]+).*$/gm);
	                for (const edge of edges) {
	                    data[gpuNumber]['"'"'edges'"'"'].push(edge[1]);
	                }

	                for (const [k, gpu] of data.entries()) {
	                    if (gpu.edges.length > 0) {
	                        output += '"'"' | 核显: '"'"';
	                        for (const edgeTemp of gpu.edges) {
	                            output += `${edgeTemp}°C, `;
	                        }
	                        output = output.slice(0, -2);
	                    }
	                }
	            }

	            let FunStates = value.matchAll(/^[a-zA-z]{2,3}\d{4}-isa-(\w{4})$\\n((?![ \S]+: *\d+ +RPM)[ \S]*?\\n)*((?:[ \S]+: *\d+ RPM)[\s\S]*?^\\n)+/gm);
	            for (const FunState of FunStates) {
	                let FanNumber = 0;
	                data[FanNumber] = {
	                    rotationals: [],
	                    cpufans: [],
	                    pumpfans: [],
	                    systemfans: []
	                };

	                let rotationals = FunState[3].match(/^([ \S]+: *[0-9]\d* +RPM)[ \S]*?$/gm);
	                for (const rotational of rotationals) {
	                    if (rotational.toLowerCase().indexOf("pump") !== -1 || rotational.toLowerCase().indexOf("opt") !== -1){
	                        let pumpfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const pumpfan of pumpfans) {
	                            data[FanNumber]['"'"'pumpfans'"'"'].push(pumpfan[1]);
	                        }
	                    } else if (rotational.toLowerCase().indexOf("cpu") !== -1){
	                        let cpufans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const cpufan of cpufans) {
	                            data[FanNumber]['"'"'cpufans'"'"'].push(cpufan[1]);
	                        }
	                    } else {
	                        let systemfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const systemfan of systemfans) {
	                            data[FanNumber]['"'"'systemfans'"'"'].push(systemfan[1]);
	                        }
	                    }
	                }

	                for (const [j, FunState] of data.entries()) {
	                    if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0 || FunState.systemfans.length > 0) {
	                        output += '"'"' | 风扇: '"'"';
	                        if (FunState.cpufans.length > 0) {
	                            output += '"'"'CPU-'"'"';
	                            for (const cpufan_value of FunState.cpufans) {
	                                output += `${cpufan_value}转/分钟, `;
	                            }
	                        }

	                        if (FunState.pumpfans.length > 0) {
	                            output += '"'"'水冷-'"'"';
	                            for (const pumpfan_value of FunState.pumpfans) {
	                                output += `${pumpfan_value}转/分钟, `;
	                            }
	                        }

	                        if (FunState.systemfans.length > 0) {
	                            if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0) {
	                                output += '"'"'系统-'"'"';
	                            }
	                            for (const systemfan_value of FunState.systemfans) {
	                                output += `${systemfan_value}转/分钟, `;
	                            }
	                        }
	                        output = output.slice(0, -2);
	                    } else if (FunState.cpufans.length == 0 && FunState.pumpfans.length == 0 && FunState.systemfans.length == 0) {
	                        output += '"'"' | 风扇: 停转'"'"';
	                    }
	                }
	            }
	        }

	        return output.replace(/\\n/g, '"'"'<br>'"'"');
	    }
	}'
    fi

    # NVME 硬盘信息 API 及 Web UI
    nvme_height="0"
    if [ $(ls /dev/nvme? 2> /dev/null | wc -l) -gt 0 ]; then
        i="1"
        nvme_info_api=''
        nvme_info_display=''
        for nvme_device in $(ls -1 /dev/nvme?); do
            nvme_code=${nvme_device##*/}
	        if [[ $(smartctl -a $nvme_device|grep -E "Cycle") && $(iostat -d -x -k 1 1 | grep -E "^$nvme_code") ]] && [[ $(smartctl -a $nvme_device|grep -E "Model") || $(smartctl -a $nvme_device|grep -E "Capacity") ]]; then
	            nvme_degree="2"
	        else
	            nvme_degree="1"
	        fi
            nvme_tmp_height="$[nvme_degree*17+7]"
			nvme_height="$[nvme_height + nvme_tmp_height]"
            nvme_info_api_tmp='
	my $'$nvme_code'_temperatures = `smartctl -a '$nvme_device'|grep -E "Model Number|Total NVM Capacity|Temperature:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors"`;
	my $'$nvme_code'_io = `iostat -d -x -k 1 1 | grep -E "^'$nvme_code'"`;
	$res->{'$nvme_code'_status} = $'$nvme_code'_temperatures . $'$nvme_code'_io;
		'
        nvme_info_api="$nvme_info_api$nvme_info_api_tmp"

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
hdd_height="0"
if [ $(ls /dev/sd? 2> /dev/null | wc -l) -gt 0 ]; then
    i="1"
    hdd_info_api=''
    hdd_info_display=''
    for hdd_device in $(ls -1 /dev/sd?); do
        hdd_code=${hdd_device##*/}
	    if [[ $(smartctl -a $hdd_device|grep -E "Cycle") && $(iostat -d -x -k 1 1 | grep -E "^$hdd_code") ]] && [[ $(smartctl -a $hdd_device|grep -E "Model") || $(smartctl -a $hdd_device|grep -E "Capacity") ]]; then
	        hdd_degree="2"
	    else
	        hdd_degree="1"
	    fi
	hdd_tmp_height="$[hdd_degree*17+7]"
	hdd_height="$[hdd_height + hdd_tmp_height]"
        hdd_info_api_tmp='
	my $'$hdd_code'_temperatures = `smartctl -a '$hdd_device'|grep -E "Model|Capacity|Power_On_Hours|Power_Cycle_Count|Power-Off_Retract_Count|Unexpected_Power_Loss|Unexpect_Power_Loss_Ct|POR_Recovery|Temperature"`;
	my $'$hdd_code'_io = `iostat -d -x -k 1 1 | grep -E "^'$hdd_code'"`;
	$res->{'$hdd_code'_status} = $'$hdd_code'_temperatures . $'$hdd_code'_io;
		'
    hdd_info_api="$hdd_info_api$hdd_info_api_tmp"

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
	            if (m) { a.push(f[0].trim() + ': ' + m[1] + 'RPM'); }
	        }
	        return a.length ? a.join(' | ') : '-';
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
	                out.push((map[chip] || chip) + ': ' + Math.round(parseFloat(t[1])) + '°C');
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
	            if (m) { out.push(m[1].trim() + ': ' + m[2] + 'RPM'); }
	        }
	        return out.length ? out.join(' | ') : '—';
	    }
	},
PSP_SENSORS_DISP
    fi
# API
INFO_API="$cpu_info_api$nvme_info_api$hdd_info_api"
# Web UI
INFO_DISPLAY="$cpu_freq_display$cpu_temp_display$nvme_info_display$hdd_info_display"

# 缓存代码
# echo -e "\n" > /tmp/0.txt
# echo -e "	    value: '',\n	}," > /tmp/1.txt
echo -e "$INFO_API" > /tmp/2.txt
echo -e "	    value: '',\n	}$INFO_DISPLAY" > /tmp/3.txt

# CPU 主频及温度 UI 高度
cpu_degree="$(sensors 2>/dev/null | grep $cpu_keyword | wc -l)"
core_degree="$(sensors 2>/dev/null | grep Core | wc -l)"
process_degree="$(cat /proc/cpuinfo | grep -i "cpu MHz" | wc -l)"
if [ $core_degree -gt 4 ]; then
    cpu_temp_degree="$[cpu_degree + (core_degree+4-1)/4]"
else
    cpu_temp_degree="$cpu_degree"
fi
cpu_temp_height="$[cpu_temp_degree*17+7]"
cpu_freq_degree="$[cpu_degree + (process_degree+4-1)/4]"
cpu_freq_height="$[cpu_freq_degree*17+7]"

# Web UI 总高度
#height1="$[400 + (cpu_temp_height + cpu_freq_height + nvme_height + hdd_height)]"
#height1="400"
height2="$[300 + cpu_temp_height + cpu_freq_height + nvme_height + hdd_height + 25]"
if [ $height2 -le 325 ]; then
    height2="300"
fi

    # 温度、风扇两独立行的余量（两模式一致）
    height2=$(( ${height2:-300} + 102 ))
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

# 生成采集脚本内容（全局 COLLECTOR）：普通 root 上下文跑硬件命令、把各字段写入 $RUN_DIR/<field>。
# 与前端 textField 同名（cpu_frequency / cpu_temperatures / <dev>_status），供后端只读回填。
# 采集在 pvedaemon 之外运行 => 无 perl -T 污点、且能访问 /dev/ipmi0 与 /dev/nvme*（守护进程内两者均受限）。
_build_collector() {
    local dev code
    COLLECTOR="#!/usr/bin/env bash
export LC_ALL=C
D='${RUN_DIR}'
mkdir -p \"\$D\"
# 临时文件用隐藏名 + PID：后端 reader 跳过点开头文件、且并发采集不撞名；mv 原子替换
_w() { local t=\"\$D/.wtmp.\$1.\$\$\"; cat > \"\$t\" 2>/dev/null && mv -f \"\$t\" \"\$D/\$1\"; }
{ lscpu | grep MHz; cat /proc/cpuinfo | grep -i 'cpu MHz'; } 2>/dev/null | _w cpu_frequency
"
    if [ "${MODE:-sensors}" = "ipmi" ]; then
        COLLECTOR+="ipmitool sdr type Temperature 2>/dev/null | _w cpu_temperatures
ipmitool sdr type Fan 2>/dev/null | _w cpu_fans
"
    else
        COLLECTOR+="sensors 2>/dev/null | _w cpu_temperatures
"
    fi
    # iostat 采一次，供各盘复用（避免每盘各跑一次 1s 采样）
    COLLECTOR+="_iostat=\"\$(iostat -d -x -k 1 1 2>/dev/null)\"
"
    for dev in $(ls -1 /dev/nvme? 2>/dev/null); do
        code="${dev##*/}"
        COLLECTOR+="{ smartctl -a ${dev} 2>/dev/null | grep -E 'Model Number|Total NVM Capacity|Temperature:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors'; echo \"\$_iostat\" | grep -E '^${code}'; } | _w ${code}_status
"
    done
    for dev in $(ls -1 /dev/sd? 2>/dev/null); do
        code="${dev##*/}"
        COLLECTOR+="{ smartctl -a ${dev} 2>/dev/null | grep -E 'Model|Capacity|Power_On_Hours|Power_Cycle_Count|Power-Off_Retract_Count|Unexpected_Power_Loss|Unexpect_Power_Loss_Ct|POR_Recovery|Temperature'; echo \"\$_iostat\" | grep -E '^${code}'; } | _w ${code}_status
"
    done
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

    # ---- 部署采集器并立即采一次 ----
    # pvedaemon 的 Web API 跑在 perl -T 污点模式、且其上下文看不到 /dev/ipmi0、/dev/nvme*，故不能在 status
    # 处理函数里直接跑 ipmitool/smartctl（反引号 → "Insecure dependency" 500；run_command → 设备打不开）。
    # 解耦：采集器在普通 root 上下文跑命令写 $RUN_DIR，后端只“读文件”回填——无污点、不碰设备、且更快。
    # （CLI pvesh 不走 -T 也不受设备限制，故此前用 pvesh 验证未能暴露，须用真实 HTTP API 验证。）
    printf '%s\n' "$COLLECTOR" > "$COLLECTOR_BIN"; chmod 0755 "$COLLECTOR_BIN"
    "$COLLECTOR_BIN" >/dev/null 2>&1 || true

    # ---- 后端 Nodes.pm：注入“只读 $RUN_DIR 回填 $res”静态块（file_get_contents，-T 安全）+ perl -c 兜底 ----
    _ensure_orig "$NODES_PM"
    api_tmp="$(mktemp)"
    {
        printf '        # %s\n' "$MARK_BEGIN"
        cat <<'PSP_READER'
        {
            my $psp_dir = '/run/pve-status-panel';
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
    systemctl start "$TIMER" 2>/dev/null || true    # 若已装 timer 则确保在跑（周期刷新采集）
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
    systemctl stop "$TIMER" 2>/dev/null
    rm -f "$COLLECTOR_BIN"
    rm -rf "$RUN_DIR"
    systemctl restart pvedaemon pveproxy 2>/dev/null
    log "已还原官方原版（采集器已停）。浏览器 Ctrl+Shift+R 强刷。"
}

status() {
    echo "模式(自动探测)   : $(detect_mode)"
    echo "Nodes.pm 已注入   : $(grep -q "$MARK_BEGIN" "$NODES_PM" && echo yes || echo no)"
    echo "pvemanagerlib 注入: $(grep -q "$MARK_BEGIN" "$PVEMGR_JS" && echo yes || echo no)"
    echo "原文件快照(.orig) : $(ls "$STATE_DIR"/*.orig 2>/dev/null | wc -l) 个"
    echo "APT 自愈 hook     : $([ -f /etc/apt/apt.conf.d/99-pve-status-panel ] && echo installed || echo absent)"
    echo "采集器 timer      : $(systemctl is-active "$TIMER" 2>/dev/null || echo inactive)"
    echo "采集数据          : $(ls "$RUN_DIR" 2>/dev/null | wc -l) 个字段 @ $RUN_DIR"
}

case "${1:-}" in
    apply)   apply ;;
    restore) restore ;;
    status)  status ;;
    *) echo "用法: $0 {apply|restore|status}"; exit 2 ;;
esac
