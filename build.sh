#!/bin/bash

# === 脚本配置 ===
IMAGE_NAME="qnap8528-compiler"
CONTAINER_NAME="qnap8528-container"
SOURCE_CODE_DIR="./src"
MODULE_OUTPUT_DIR="/lib/modules/$(uname -r)/extra"
KERNEL_VERSION=$(uname -r)
KERNEL_HEADERS_DIR="/usr/src/linux-headers-$KERNEL_VERSION"
DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)

# === 前置检查 ===
# 检查 Docker 服务状态
if ! systemctl is-active --quiet docker; then
    echo "❌ 错误：Docker 服务未运行，请先启动 Docker"
    exit 1
fi

# 检查内核头文件是否存在
if [ ! -d "$KERNEL_HEADERS_DIR" ]; then
    echo "❌ 错误：未找到内核头文件 $KERNEL_HEADERS_DIR"
    echo "📦 请先安装对应版本的内核开发包（通常为 linux-headers-$KERNEL_VERSION, PVE下为proxmox-headers-$KERNEL_VERSION）"
    exit 1
fi

# === 镜像管理 ===
build_image() {
    echo "🔄 正在构建 Docker 镜像 ($IMAGE_NAME)..."
    docker build --build-arg DEBIAN_VERSION="$DEBIAN_VERSION" -t "$IMAGE_NAME" -f Dockerfile .
    if [ $? -ne 0 ]; then
        echo "❌ 镜像构建失败，请检查 Dockerfile 或网络连接"
        exit 1
    fi
    echo "✅ 镜像构建成功"
}

# 检查并处理镜像
if docker images -q "$IMAGE_NAME" | grep -q .; then
    read -p "⚠️ 检测到已有镜像，是否重新构建？(y/N): " choice
    [[ $choice =~ ^[Yy]$ ]] && build_image
else
    build_image
fi

# === 容器管理 ===
clean_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        echo "🧹 清理旧容器 $CONTAINER_NAME..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1
    fi
}

start_container() {
    clean_container
    echo "🚀 启动 Docker 容器..."
    docker run -itd \
        --name "$CONTAINER_NAME" \
        -v "$SOURCE_CODE_DIR:/driver" \
        -v "$KERNEL_HEADERS_DIR:/usr/src/linux-headers" \
        "$IMAGE_NAME" bash
    if [ $? -ne 0 ]; then
        echo "❌ 容器启动失败，请检查挂载路径或镜像完整性"
        exit 1
    fi
}

# === 编译流程 ===
compile_driver() {
    echo "🔨 开始编译内核模块..."
    docker exec -it "$CONTAINER_NAME" bash -c "
        cd /driver && \
        make -C /usr/src/linux-headers M=\$PWD modules
    "
    if [ $? -ne 0 ]; then
        echo "❌ 编译失败，请检查代码或内核头文件兼容性"
        clean_container
        exit 1
    fi
    echo "✅ 编译成功"
}

# === 安装流程 ===
install_driver() {
    echo "📦 安装驱动到系统..."
    mkdir -p "$MODULE_OUTPUT_DIR"
    cp "$SOURCE_CODE_DIR"/*.ko "$MODULE_OUTPUT_DIR"
    depmod -a
    local driver_name=$(basename "$SOURCE_CODE_DIR"/*.ko .ko)
    modprobe "$driver_name"
    echo "✅ 驱动 $driver_name 已加载"
    
    # 配置 systemd 开机自启（替代旧的 /etc/modules-load.d 方式）
    cat <<EOF | tee /etc/systemd/system/qnap8528-load.service >/dev/null
[Unit]
Description=Load qnap8528 Kernel Module
After=syslog.target network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe $driver_name
ExecStop=/sbin/modprobe -r $driver_name

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable --now qnap8528-load.service >/dev/null
    echo "⚙️ 已配置开机自动加载"
}

# === 清理资源 ===
clean_resources() {
    echo "🧹 清理临时容器..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1
}

# === 传感器检测 ===
check_sensors() {
    echo "📊 检测传感器数据..."
    if ! command -v sensors &> /dev/null; then
        echo "⚠️ 警告：sensors 工具未安装，跳过传感器检测"
        return
    fi
    local sensor_data=$(sensors | awk '/qnap8528/,/^$/')
    if [ -n "$sensor_data" ]; then
        echo "🌡️ qnap8528 传感器信息："
        echo "$sensor_data"
    else
        echo "❌ 未检测到 qnap8528 传感器数据（可能驱动未正确加载）"
    fi
}

# === 主流程 ===
main() {
    start_container
    compile_driver
    install_driver
    clean_resources
    check_sensors
}

# 以 root 权限执行核心操作
if [ "$EUID" -ne 0 ]; then
    echo "🔒 请使用 root 权限运行脚本（sudo ./build.sh）"
    exit 1
fi

main
