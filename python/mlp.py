import numpy as np
import tensorflow as tf
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import Dense, Flatten, Dropout
from tensorflow.keras.utils import to_categorical
import matplotlib.pyplot as plt
import seaborn as sns
from sklearn.metrics import confusion_matrix

# =====================================================================
# 1. TẢI VÀ TIỀN XỬ LÝ DỮ LIỆU
# =====================================================================
print("Đang tải tập dữ liệu MNIST từ thư viện...")
mnist = tf.keras.datasets.mnist
(x_train_raw, y_train), (x_test_raw, y_test) = mnist.load_data()
y_test_originals = y_test.copy()

# Dữ liệu chuẩn hóa [0..1] chỉ dùng trong lúc train để Adam hội tụ tốt nhất
# và giữ biên độ ngõ ra các tầng nhỏ (tránh tràn số 17-bit trên RTL)
x_train_norm = x_train_raw.astype('float32') / 255.0
x_test_norm  = x_test_raw.astype('float32') / 255.0

# Dữ liệu gốc [0..255] (không chuẩn hóa) dùng trực tiếp cho kiểm tra và RTL
x_test_unnorm = x_test_raw.astype('float32')

y_train = to_categorical(y_train, 10)
y_test = to_categorical(y_test, 10)

# =====================================================================
# 2. XÂY DỰNG VÀ HUẤN LUYỆN MÔ HÌNH MLP
# =====================================================================
model = Sequential([
    Flatten(input_shape=(28, 28)),    # 1. Duỗi ảnh 2D thành vector 1D (28x28 = 784 ngõ vào)
    Dense(64, activation='relu'),     # 2. Tầng ẩn 1: 64 nơ-ron
    Dropout(0.1),
    #Dense(10, activation='softmax')  # 4. Tầng đầu ra: 10 nơ-ron
    Dense(10, activation=None)
])

#model.compile(loss="categorical_crossentropy", optimizer="adam", metrics=["accuracy"])
model.compile(loss=tf.keras.losses.CategoricalCrossentropy(from_logits=True), optimizer="adam", metrics=["accuracy"])

print("\nBắt đầu huấn luyện mô hình MLP...")
history = model.fit(
    x_train_norm, y_train,
    batch_size=128,
    epochs=10,
    validation_data=(x_test_norm, y_test),
    verbose=1
)

# =====================================================================
# 3. GỘP CHUẨN HÓA (/ 255.0) VÀO TRỌNG SỐ W1 ĐỂ RTL KHÔNG CẦN CHIA 255
# =====================================================================
# Ta có: W1 * (x_raw / 255.0) + b1 = (W1 / 255.0) * x_raw + b1
# Nhờ gộp / 255.0 vào W1, mạch RTL nhận trực tiếp pixel 8-bit [0..255]
W1, b1 = model.layers[1].get_weights()   # Dense(64): W1 (784,64), b1 (64,)
W2, b2 = model.layers[3].get_weights()   # Dense(10): W2 (64,10),  b2 (10,)

W1 = W1 / 255.0                          # Gộp bước chia 255.0 vào W1
model.layers[1].set_weights([W1, b1])    # Cập nhật lại model để chạy trực tiếp với ảnh [0..255]

# Xuất trọng số đã gộp chuẩn hóa
np.save('W1.npy', W1); np.save('b1.npy', b1)
np.save('W2.npy', W2); np.save('b2.npy', b2)

# Xuất 20 ảnh mẫu giữ nguyên dạng pixel 8-bit (0–255) cho Testbench RTL
np.save('x_sample.npy', x_test_raw[:20].astype(np.uint8))       # 20 ảnh, mỗi ảnh 28x28 (uint8: 0..255)
np.save('y_sample.npy', y_test_originals[:20])                  # nhãn đúng tương ứng
print("Da xuat: W1 (da gop /255), b1, W2, b2, x_sample, y_sample (.npy)")

# =====================================================================
# 4. ĐÁNH GIÁ TRỰC TIẾP TRÊN ẢNH GỐC 8-BIT [0..255] VÀ VẼ ĐỒ THỊ
# =====================================================================
score = model.evaluate(x_test_unnorm, y_test, batch_size=128, verbose=0)
print("\n" + "="*50)
print("   KẾT QUẢ ĐÁNH GIÁ TRỰC TIẾP TRÊN ẢNH [0..255]   ")
print("="*50)
print(f"Test Loss (raw 0..255 input):     {score[0]:.4f}")
print(f"Test Accuracy (raw 0..255 input): {score[1]*100:.2f}%")
print("="*50)

plt.figure(figsize=(12, 5))

# Đồ thị Accuracy
plt.subplot(1, 2, 1)
plt.plot(history.history['accuracy'], 'bo-', label='Training Accuracy')
plt.plot(history.history['val_accuracy'], 'ro-', label='Validation Accuracy')
plt.title('Training and Validation Accuracy')
plt.xlabel('Epochs')
plt.ylabel('Accuracy')
plt.legend()
plt.grid(True)

# Đồ thị Loss
plt.subplot(1, 2, 2)
plt.plot(history.history['loss'], 'bo-', label='Training Loss')
plt.plot(history.history['val_loss'], 'ro-', label='Validation Loss')
plt.title('Training and Validation Loss')
plt.xlabel('Epochs')
plt.ylabel('Loss')
plt.legend()
plt.grid(True)

plt.show()

# =====================================================================
# 5. VẼ CONFUSION MATRIX (DỰ ĐOÁN TRỰC TIẾP TỪ ẢNH [0..255])
# =====================================================================
predictions = model.predict(x_test_unnorm)
predicted_labels = np.argmax(predictions, axis=1)

cm = confusion_matrix(y_test_originals, predicted_labels)
plt.figure(figsize=(10, 8))
sns.heatmap(cm, annot=True, fmt='d', cmap='Blues', xticklabels=range(10), yticklabels=range(10))
plt.xlabel('Predicted')
plt.ylabel('Actual')
plt.title('Confusion Matrix (Direct 0..255 Input)')
plt.show()

# =====================================================================
# 6. HIỂN THỊ ẢNH MẪU DỰ ĐOÁN
# =====================================================================
plt.figure(figsize=(15, 6))
random_indices = np.random.choice(x_test_raw.shape[0], 10, replace=False)
for i, idx in enumerate(random_indices):
    plt.subplot(2, 5, i + 1)
    plt.imshow(x_test_raw[idx].reshape(28, 28), cmap='gray')
    pred, actual = predicted_labels[idx], y_test_originals[idx]
    color = 'green' if pred == actual else 'red'
    plt.title(f"Thực tế: {actual}\nDự đoán: {pred}", color=color)
    plt.axis('off')
plt.tight_layout()
plt.show()
