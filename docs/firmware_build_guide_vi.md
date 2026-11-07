# Build BRAM CPU COE bằng RISC-V GCC trên Ubuntu

Luồng thực hiện:
`start.S + main.c + linker.ld -> RISC-V GCC -> firmware.elf -> objcopy -> firmware.bin -> Python ghép ảnh -> bram_cpu.coe`.
Python KHÔNG mã hóa instruction. Toàn bộ instruction được assembler/compiler/linker của GCC toolchain tạo ra.

## Cài toolchain nếu máy chưa có

```bash
sudo apt update
sudo apt install gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf python3
```

Tên toolchain là riscv64 nhưng build.sh truyền `-march=rv32i -mabi=ilp32` để tạo firmware 32 bit cho PicoRV32. Không dùng GCC x86 của Ubuntu hoặc toolchain Linux/glibc để build trực tiếp firmware này. Nếu đã có toolchain riscv32-unknown-elf thì script tự chọn nó khi không tìm thấy bản riscv64.

## Build

Giải nén, mở terminal trong thư mục soc_gcc:

```bash
bash build.sh
```

Lệnh trên dùng 784 byte ảnh tổng hợp kiểm tra đường truyền, không phải ảnh MNIST có nhãn. Dữ liệu trọng số gốc đã kèm trong `weights_original.coe`.

Dùng ảnh của bạn (đúng 28x28):

```bash
bash build.sh /duong/dan/image_28x28.png
```

PNG/JPG cần Pillow; có thể cài `sudo apt install python3-pil`. Script chuyển grayscale nhưng không tự resize hoặc đảo màu. Phải dùng cùng tiền xử lý với lúc huấn luyện. Có thể dùng .bin đúng 784 byte hoặc .txt/.csv gồm 784 số nguyên thập phân 0..255 để không cần Pillow.

Nếu toolchain nằm ở vị trí riêng:

```bash
CROSS_COMPILE=/opt/riscv/bin/riscv32-unknown-elf- bash build.sh
```

Đường dẫn ảnh tương đối được tính từ thư mục chứa build.sh; đường dẫn tuyệt đối dùng được ở mọi nơi.

## Kết quả

| Tệp trong build/ | Công dụng |
|---|---|
| firmware.elf | ELF do GCC build |
| firmware.bin | Binary do objcopy xuất |
| firmware.dis | Disassembly để kiểm tra instruction thực tế |
| firmware.map | Địa chỉ các section/symbol |
| bram_cpu.coe | Nạp vào BRAM CPU trong Vivado |
| bram_cpu.mem | Cùng nội dung COE, dùng với `$readmemh` trong testbench |
| image.mem | Ảnh kỳ vọng để scoreboard kiểm tra |
| weights.mem | Trọng số dùng trong mô hình BRAM mô phỏng |
| expected_hidden.mem, expected_logits.mem, expected_result.mem | Tham chiếu số học cho testbench đã gửi |
| manifest.json | Thông số bộ nhớ và kết quả tham chiếu |

Không có COE hay ELF GCC đã build sẵn trong gói này. Chạy build.sh trên Ubuntu của bạn để tạo chúng. Không lấy lại COE do encoder Python ở bộ trước làm kết quả build GCC.

## Memory map và cấu hình

- CPU BRAM 32 bit × 16384 word = 64 KiB, base 0, `BRAM_SIZE=0x10000`.
- Entry `_start` ở 0; PicoRV32 `PROGADDR_RESET=0`.
- Code/static data/BSS nằm dưới `0x1000`; linker báo lỗi nếu vượt vùng này.
- Ảnh: 784 byte từ `0x1000` đến `0x130F`, row-major, little-endian khi ghép word.
- Kết quả: `0x2000`; marker hoàn tất: `0x2004`.
- Stack được đặt SP=`0x10000`, dành vùng `0xF000..0xFFFF` cho chương trình nhỏ này.
- MLP MMIO: base `0x10000000`, size `0x1000`; offset CONTROL/STATUS/PIXEL_DATA/PIXEL_COUNT/RESULT tương ứng `0/4/8/12/16`.
- BRAM trọng số độc lập: giữ COE trọng số cũ; weights_loaded nối 1 khi khởi tạo sẵn.

Chọn build/bram_cpu.coe ở Load Init File của Block Memory Generator CPU, regenerate output products. Duy trì latency 1 theo controller bạn đã thiết kế.

main.c thực hiện CLEAR=2 → gửi đủ 784 pixel → kiểm tra PIXEL_COUNT → START=1 → chờ STATUS bit 1 → đọc RESULT → ghi mailbox và marker 0x600D0001 → lặp vô hạn. Nếu pixel count sai, ghi marker 0xFFFFFFFF. Không sử dụng M/C extension, IRQ, libc hoặc phép toán cần libgcc. BSS được startup xóa; dữ liệu initialized nằm ngay trong BRAM đã nạp COE, không cần copy từ ROM khác.

## Dùng với testbench đã gửi trước đó

Giữ tb_soc_mlp.v, sử dụng các RTL đã sửa của bạn. Đổi sáu parameter đường dẫn .mem trong testbench sang các tệp tương ứng trong thư mục build mới. Dùng toàn bộ tệp từ cùng một lần build để ảnh/reference không bị lệch. Testbench vẫn dùng mô hình CPU RAM thay cho bram_controller thật như đã ghi rõ trong bộ trước.

## Mức kiểm chứng

Đã kiểm tra cú pháp shell/Python và bộ ghép binary + ảnh: giữ nguyên từng byte firmware đầu vào, đúng vị trí ảnh, đủ 16384 word, COE và MEM giống nhau. Môi trường tạo bộ tệp không có RISC-V GCC hoặc Vivado, vì vậy chưa xác nhận build GCC hoặc mô phỏng RTL thành công tại đây. Nếu GCC báo lỗi, gửi toàn bộ log và phiên bản toolchain để đối chiếu.
