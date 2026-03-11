---
title: class的模版和使用
date: 2026-03-11 20:44:57
tags: 算法
---

```c++
#include <iostream>
using namespace std;

// 通用类模板
class MyClass {
public:
    int val;       // 一个成员变量
    double score;  // 可以再加一个成员变量

    // 默认构造函数
    MyClass() {
        val = 0;
        score = 0.0;
    }

    // 单参数构造函数
    MyClass(int _val) {
        val = _val;
        score = 0.0;
    }

    // 多参数构造函数
    MyClass(int _val, double _score) {
        val = _val;
        score = _score;
    }

    // 成员函数示例
    void print() {
        cout << "val=" << val << ", score=" << score << endl;
    }
};

int main() {
    MyClass a;               // 默认构造        这两种创建方式要注意！！！
    MyClass* b = new MyClass(30);  // 对象 b 在堆上     这两种创建方式要注意！！！
    MyClass c(20, 95.5);     // 多参数构造

    a.print();  // 输出: val=0, score=0
    b.print();  // 输出: val=30, score=0
    c.print();  // 输出: val=20, score=95.5

    return 0;
}
```