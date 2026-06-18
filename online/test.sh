#!/system/bin/sh
export PATH="/data/local/tmp:$PATH"
echo "=== 测试 mimo ==="
mimo --version
echo ""
echo "=== 测试 bash ==="
bash --version | head -1
echo ""
echo "=== 测试 python3 ==="
python3 --version
