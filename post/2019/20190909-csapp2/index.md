# 读CSAPP(2) - 程序性能优化



## 高效的程序需要做到
1. 合适的数据结构与算法
2. 编写出编译器能够有效优化以转换成高效可执行代码的源码。
3. 将运算量特别大的计算，可以分成多部分，这些部分可以在多核多处理器的某种组合上并行处理

本篇主要以第二点进行讨论，编译器在优化的时候只会做最坏打算，做各种假设。为了保证程序的准确性，舍弃性能优化。
## 编译器的优化限制
### 内存别名的使用

```c
void twiddle1(long *xp, long *yp)
{
	*xp += *yp;
	*xp += *yp;
}

void twiddle2(long *xp, long *yp)
{
	*xp += 2* *yp;
}
```
上面两个程序twiddle2（读xp，读yp，写xp）优于twiddl1（读2次xp，读2次yp，写2次xp）。
看起来编译器也许会将twiddle1优化成twiddle2的形式。但假设*xp和*yp是引用的同一个内存地址：&xp = &yp
```c
void twiddle1(long *xp, long *yp){
	*xp += *xp;
	*xp += *xp;
}

void twiddle2(long *xp, long *yp){
	*xp += 2* *xp;
}
```
代码则可以写成上面这样，这时候两个函数的意义就不同了，twiddle1将*xp增加了4倍，twiddle2将*xp增加了3倍。
两个指针指向同一个内存地址，称之为：内存别名使用，编译器必须假设不同指针可能指向相同地址，限制了优化策略

### 函数调用
```c
long f();

long func1(){
	return f() + f() + f() + f()
}

long func2(){
	return 4*f()
}
```
看起来两个函数结果是相同的，但假设函数f内部为：

```c
long counter = 0;
long f(){
	return counter ++;
}
```

那么func1和func2返回结果就不同了，而且修改全局状态也不同。
大多数编译器不会试图判断一个函数是否没有副作用，如果没有，可能被优化成func2的形式。否则假设最糟糕的情况，保持不变。

> 用内联函数减少开销，也对展开代码做了优化。

## 对一段代码的优化案例
下面程序是将元素累加，之后我们对combine1函数进行一步步优化

```c
int get_vec_element(vec_ptr v, long index, data_t *dest){
	if (index < 0 || index >= v->len)
		return 0;
	*dest = v->data[index]
	return 1;
}

long vec_length(vec_ptr v){
	return v->len;
}

void combine1(vec_ptr v, data_t *dest){
	long i;
	*dest = 0;
	for(i = 0; i < vec_length(v); i++ )
	{
		data_t val;
		get_vec_element(v, i, &val);
		*dest = *dest + val;
	}
}
```

### 1. 消除循环的低效率
将幂等函数移动出循环

```c
void combine2(vec_ptr v, data_t *dest){
	long i;
	*dest = 0;
	long length = vec_length(v);
	for(i = 0; i < length; i++ )
	{
		data_t val;
		get_vec_element(v, i, &val);
		*dest = *dest + val;
	}
}
```

### 2. 减少过程调用
get_vec_element中对边界检查，虽然很有用，但在本例中能明显看出所有引用都是合法，可以去除
```c
void combine3(vec_ptr v, data_t *dest){
	long i;
	*dest = 0;
	long length = vec_length(v);
	data_t *data = v->data; //获取首地址
	for(i = 0; i < length; i++ )
	{
		*dest = *dest + data[i];
	}
}
```

### 3. 消除不必要的内存引用
combine3将计算值累积在指针dest位置，每次循环都会进行三步操作

1. 读取dest值 
2. 读取data[i]值 
3. 写入dest所在内存

从dest读取的值，就是上次写入dest的值，加上个临时的变量

1. 读data[i]值，计算结果放到临时内存 
2. 内存的值不写入，当循环完毕最后在写入到dest

优化后每次循环只需要读取一次data[i]值即可。

```c
void combine4(vec_ptr v, data_t *dest){
	long i;
	data_t acc = 0;
	long length = vec_length(v);
	data_t *data = v->data; //获取首地址
	for(i = 0; i < length; i++ )
	{
		acc = acc + data[i];
	}
	*dest = acc;
}
```

编译器应该也会帮我们优化成combine4的形式，但由于内存别名的使用，可能会有不同行为。
比如 *dest引用的是data的地址，那结果会有区别，所以不会优化。

### 4. 循环展开
增加每次循环迭代计算的元素数量，减少迭代次数。

```c
void combine5(vec_ptr v, data_t *dest){
	long i;
	data_t acc = 0;
	long length = vec_length(v) - 1;
	data_t *data = v->data; //获取首地址
	for(i = 0; i < length; i+=2 )
	{
		acc = (acc + data[i])+ data[i+1];
	}
	*dest = acc;
}
```
编译器一般会帮助我们进行循环展开操作，只要优化等级3或更高。

### 5. 提高并行性
在代码层面，下面三行是一条条按序执行，但cpu发现a和b的赋值操作是互不影响的，会同时执行a和b，这种现象叫做：指令级并行。
```c
int a = 1;
int b = 2;
int c = a + b;
```

所以我们可以将combine5的代码再进行一次优化：
```c
void combine6(vec_ptr v, data_t *dest){
	long i;
	data_t acc0 = 0;
	data_t acc1 = 0;
	long length = vec_length(v) - 1;
	data_t *data = v->data; //获取首地址
	for(i = 0; i < length; i+=2 )
	{
		acc0 = acc0 + data[i];
		acc1 = acc1 + data[i+1];
	}
	*dest = acc0 + acc1;
}
```
combine5的循环展开，将循环次数减少了一半，提高了效率。但是cpu执行还是按序执行，无法进行并行操作，因为新的acc值总要依靠上一个acc，必须按顺序执行，才能获取。
现在将奇数索引的值赋给acc0，偶数索引的值赋给acc1，两个变量互不影响，cpu就可以进行并行操作了，最后将结果相结合


>循环展开的数量并不是越多效率越高，循环的变量一旦超过可用寄存器数量，效率反而会更慢。

### 6. 分支预测
#### 案例
[代码引用-婉儿飞飞](https://zhuanlan.zhihu.com/p/22469702)

下面代码，对数组值大于等于128的进行求和。求和前进行排序要比不进行排序直接求和效率要高3倍左右。

```c
#include <algorithm>
#include <ctime>
#include <iostream>

int main()
{
    // 随机产生整数，用分区函数填充，以避免出现分桶不均
    const unsigned arraySize = 32768;
    int data[arraySize];

    for (unsigned c = 0; c < arraySize; ++c)
        data[c] = std::rand() % 256;

    // !!! 排序后下面的Loop运行将更快
    std::sort(data, data + arraySize);

    // 测试部分
    clock_t start = clock();
    long long sum = 0;

    for (unsigned i = 0; i < 100000; ++i)
    {
        // 主要计算部分，选一半元素参与计算
        for (unsigned c = 0; c < arraySize; ++c)
        {
            if (data[c] >= 128)
                sum += data[c];
        }
    }

    double elapsedTime = static_cast<double>(clock() - start) / CLOCKS_PER_SEC;

    std::cout << elapsedTime << std::endl;
    std::cout << "sum = " << sum << std::endl;
}
```

cpu对分支进行预测，猜测下一步走哪个分支。如果猜对，cpu不会暂停一直运行，猜错，就要停止-回滚-热启动。
cpu根据历史进行猜测下一步走向。有序的数组，预测判断条件的结果更加准确，无序数组无法预测，命中率低，导致效率低。

#### 优化方案
1. 如果可以的话移除分支
```c
//用位运算 替换 if判断
int t = (data[c] - 128) >> 31;
sum += ~t & data[c];
```

2. 提高分支的可预测性，比如上面先排序

### 优化总结
- 消除函数调用
- 消除不必要的内存引用
- 循环展开
- 提高指令并行
- 提高分支的预测性

### 参考
[stackoverflow-分支预测](https://stackoverflow.com/questions/11227809/why-is-processing-a-sorted-array-faster-than-processing-an-unsorted-array/11227902#11227902)
