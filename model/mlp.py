import os
import random
import zipfile
import numpy as np
import tensorflow as tf
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import Dense, Flatten, Dropout
from tensorflow.keras.utils import to_categorical
import matplotlib.pyplot as plt
import seaborn as sns
from sklearn.metrics import confusion_matrix

# =====================================================================
# 0. KHỞI TẠO SEED (ĐẢM BẢO TÁI LẬP KẾT QUẢ CHO RTL VERIFICATION)
# =====================================================================
SEED = 42
np.random.seed(SEED)
random.seed(SEED)
tf.random.set_seed(SEED)
os.environ['PYTHONHASHSEED'] = str(SEED)

# Tham số lượng tử hóa phần cứng (khớp 100% với mlp_acc.v)
FRAC_BITS = 8
SCALE     = 1 << FRAC_BITS   # 256 (Q8.8 format)

# =====================================================================
# 1. TẢI VÀ TIỀN XỬ LÝ DỮ LIỆU
# =====================================================================
print("Đang tải tập dữ liệu MNIST...")
mnist = tf.keras.datasets.mnist
(x_train_raw, y_train_orig), (x_test_raw, y_test_originals) = mnist.load_data()

# Chia cho 256.0 (2^8) thay vì 255.0:
# - Trong lúc train: dữ liệu nằm trong khoảng [0, 255/256], giúp Adam hội tụ tốt nhất
#   và giữ trọng số W1 đủ lớn (không bị nhỏ đi 255 lần).
# - Trong phần cứng RTL (mlp_acc.v): phép chia 256 chính là dịch phải 8 bit (>>> 8)
#   nên phần cứng nhận trực tiếp pixel 8-bit [0..255] mà KHÔNG cần bộ chia/chuẩn hóa!
x_train_norm = x_train_raw.astype('float32') / float(SCALE)
x_test_norm  = x_test_raw.astype('float32') / float(SCALE)

y_train = to_categorical(y_train_orig, 10)
y_test  = to_categorical(y_test_originals, 10)

# =====================================================================
# 2. XÂY DỰNG VÀ HUẤN LUYỆN MÔ HÌNH MLP
# =====================================================================
model = Sequential([
    Flatten(input_shape=(28, 28)),    # 1. Duỗi ảnh 28x28 thành 784 ngõ vào
    Dense(64, activation='relu'),     # 2. Tầng ẩn: 64 nơ-ron (ReLU)
    Dropout(0.1),
    Dense(10, activation=None)        # 3. Tầng đầu ra: 10 logits (Argmax phần cứng)
])

model.compile(
    loss=tf.keras.losses.CategoricalCrossentropy(from_logits=True),
    optimizer="adam",
    metrics=["accuracy"]
)

print("\nBắt đầu huấn luyện mô hình MLP...")
history = model.fit(
    x_train_norm, y_train,
    batch_size=128,
    epochs=10,
    validation_data=(x_test_norm, y_test),
    verbose=1
)

# =====================================================================
# 3. TRÍCH XUẤT TRỌNG SỐ & LƯỢNG TỬ HÓA Q8.8 (16-BIT SIGNED) CHO RTL
# =====================================================================
W1, b1 = model.layers[1].get_weights()   # Dense(64): W1 (784, 64), b1 (64,)
W2, b2 = model.layers[3].get_weights()   # Dense(10): W2 (64, 10),  b2 (10,)

print("\n" + "="*55)
print("     DẢI GIÁ TRỊ TRỌNG SỐ VÀ BIAS (FLOAT)     ")
print("="*55)
print(f"W1 range: [{W1.min():.6f}, {W1.max():.6f}]")
print(f"b1 range: [{b1.min():.6f}, {b1.max():.6f}]")
print(f"W2 range: [{W2.min():.6f}, {W2.max():.6f}]")
print(f"b2 range: [{b2.min():.6f}, {b2.max():.6f}]")
print("="*55)

def quantize_q8(arr):
    """Chuyển số thực float sang số nguyên có dấu 16-bit Q8.8 (nhân 256)."""
    q = np.round(arr * SCALE)
    return np.clip(q, -32768, 32767).astype(np.int16)

W1_q8 = quantize_q8(W1)   # (784, 64) int16
b1_q8 = quantize_q8(b1)   # (64,)     int16
W2_q8 = quantize_q8(W2)   # (64, 10)  int16
b2_q8 = quantize_q8(b2)   # (10,)     int16

# =====================================================================
# 4. MÔ PHỎNG BIT-ACCURATE PHẦN CỨNG RTL (mlp_acc.v) TRÊN TẬP TEST
# =====================================================================
# Kiểm tra chính xác toán học số nguyên của mlp_acc.v với ngõ vào 8-bit [0..255]:
# - Layer 1: acc1 = (b1_q8 << 8) + sum(pixel_u8 * W1_q8)
#            hidden_u16 = clip(ReLU(acc1 >> 8), 0, 65535)
# - Layer 2: acc2 = (b2_q8 << 8) + sum(hidden_u16 * W2_q8)
#            pred = argmax(acc2)
x_test_u8 = x_test_raw.reshape(-1, 784).astype(np.int32)
acc1_hw = (b1_q8.astype(np.int32) << FRAC_BITS) + np.matmul(x_test_u8, W1_q8.astype(np.int32))
hidden_hw = np.clip(np.maximum(0, acc1_hw >> FRAC_BITS), 0, 65535)
acc2_hw = (b2_q8.astype(np.int32) << FRAC_BITS) + np.matmul(hidden_hw, W2_q8.astype(np.int32))
hw_preds = np.argmax(acc2_hw, axis=1)
hw_acc = np.mean(hw_preds == y_test_originals)

score = model.evaluate(x_test_norm, y_test, batch_size=128, verbose=0)
print("\n" + "="*55)
print("          SO SÁNH ĐỘ CHÍNH XÁC FLOAT vs RTL Q8          ")
print("="*55)
print(f"Float32 Test Accuracy:              {score[1]*100:.2f}%")
print(f"Hardware Q8 Bit-Accurate Accuracy:  {hw_acc*100:.2f}% (raw 8-bit 0..255 input)")
print("="*55)

# =====================================================================
# 5. ĐÓNG GÓI BỘ NHỚ BRAM 32-BIT (KHỚP MEMORY MAP CỦA mlp_acc.v)
# =====================================================================
# Memory Map trong mlp_acc.v:
#   W1_BASE = 0     (25,088 words: l1_pair = 0..31, pixel_idx = 0..783)
#   W2_BASE = 25088 (   320 words: l2_pair = 0..4,  hidden_idx = 0..63)
#   B1_BASE = 25408 (    32 words: l1_pair = 0..31)
#   B2_BASE = 25440 (     5 words: l2_pair = 0..4)
#   Mỗi word 32-bit chứa: [15:0] = neuron chẵn (2k), [31:16] = neuron lẻ (2k+1)
def pack_two_int16(even_val, odd_val):
    u0 = int(even_val) & 0xFFFF
    u1 = int(odd_val)  & 0xFFFF
    return (u1 << 16) | u0

bram_words = []

# 1. W1: 32 pairs * 784 pixels = 25,088 words
for l1_pair in range(32):
    n0, n1 = 2 * l1_pair, 2 * l1_pair + 1
    for px in range(784):
        bram_words.append(pack_two_int16(W1_q8[px, n0], W1_q8[px, n1]))

# 2. W2: 5 pairs * 64 hidden = 320 words
for l2_pair in range(5):
    c0, c1 = 2 * l2_pair, 2 * l2_pair + 1
    for h in range(64):
        bram_words.append(pack_two_int16(W2_q8[h, c0], W2_q8[h, c1]))

# 3. B1: 32 pairs = 32 words
for l1_pair in range(32):
    n0, n1 = 2 * l1_pair, 2 * l1_pair + 1
    bram_words.append(pack_two_int16(b1_q8[n0], b1_q8[n1]))

# 4. B2: 5 pairs = 5 words
for l2_pair in range(5):
    c0, c1 = 2 * l2_pair, 2 * l2_pair + 1
    bram_words.append(pack_two_int16(b2_q8[c0], b2_q8[c1]))

assert len(bram_words) == 25445, f"Expected 25445 BRAM words, got {len(bram_words)}"

with open('weights_bram.hex', 'w') as f_hex, open('weights_bram.mem', 'w') as f_mem:
    for w in bram_words:
        line = f"{w:08x}\n"
        f_hex.write(line)
        f_mem.write(line)

# Lưu các file .npy (cả float và Q8 int16) + 20 ảnh mẫu [0..255]
np.save('W1.npy', W1);       np.save('b1.npy', b1)
np.save('W2.npy', W2);       np.save('b2.npy', b2)
np.save('W1_q8.npy', W1_q8); np.save('b1_q8.npy', b1_q8)
np.save('W2_q8.npy', W2_q8); np.save('b2_q8.npy', b2_q8)
np.save('x_sample.npy', x_test_raw[:20].astype(np.uint8))
np.save('y_sample.npy', y_test_originals[:20])
np.save('hw_pred_sample.npy', hw_preds[:20].astype(np.uint8))

# Xuất thêm file ảnh mẫu dạng hex cho Verilog $readmemh nếu cần
with open('x_sample_0.hex', 'w') as f_px:
    for px in x_test_raw[0].flatten():
        f_px.write(f"{int(px):02x}\n")

files_to_zip = [
    'W1.npy', 'b1.npy', 'W2.npy', 'b2.npy',
    'W1_q8.npy', 'b1_q8.npy', 'W2_q8.npy', 'b2_q8.npy',
    'weights_bram.hex', 'weights_bram.mem',
    'x_sample.npy', 'y_sample.npy', 'hw_pred_sample.npy', 'x_sample_0.hex'
]
zip_filename = 'mlp_weights.zip'
with zipfile.ZipFile(zip_filename, 'w') as zipf:
    for f in files_to_zip:
        if os.path.exists(f):
            zipf.write(f)
print(f"Đã xuất BRAM image (25,445 words) và đóng gói: {zip_filename}")

# =====================================================================
# 6. VẼ VÀ LƯU ĐỒ THỊ TRAINING & CONFUSION MATRIX (PHẦN CỨNG Q8)
# =====================================================================
plt.figure(figsize=(12, 5))

plt.subplot(1, 2, 1)
plt.plot(history.history['accuracy'], 'bo-', label='Training Accuracy')
plt.plot(history.history['val_accuracy'], 'ro-', label='Validation Accuracy')
plt.title('Training and Validation Accuracy')
plt.xlabel('Epochs')
plt.ylabel('Accuracy')
plt.legend()
plt.grid(True)

plt.subplot(1, 2, 2)
plt.plot(history.history['loss'], 'bo-', label='Training Loss')
plt.plot(history.history['val_loss'], 'ro-', label='Validation Loss')
plt.title('Training and Validation Loss')
plt.xlabel('Epochs')
plt.ylabel('Loss')
plt.legend()
plt.grid(True)

plt.tight_layout()
plt.savefig('training_curves.png', dpi=300)
plt.show()

cm = confusion_matrix(y_test_originals, hw_preds)
plt.figure(figsize=(10, 8))
sns.heatmap(cm, annot=True, fmt='d', cmap='Blues', xticklabels=range(10), yticklabels=range(10))
plt.xlabel('Predicted (Hardware Q8)')
plt.ylabel('Actual')
plt.title(f'Hardware Q8 Confusion Matrix (Acc: {hw_acc*100:.2f}%)')
plt.tight_layout()
plt.savefig('confusion_matrix.png', dpi=300)
plt.show()

plt.figure(figsize=(15, 6))
random_indices = np.random.choice(x_test_raw.shape[0], 10, replace=False)
for i, idx in enumerate(random_indices):
    plt.subplot(2, 5, i + 1)
    plt.imshow(x_test_raw[idx].reshape(28, 28), cmap='gray')
    pred, actual = hw_preds[idx], y_test_originals[idx]
    color = 'green' if pred == actual else 'red'
    plt.title(f"Thực tế: {actual}\n Dự đoán (HW): {pred}", color=color)
    plt.axis('off')
plt.tight_layout()
plt.savefig('sample_predictions.png', dpi=300)
plt.show()
