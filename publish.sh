#!/bin/bash

echo "📝 是否要创建新文章？(y/n)"
read create_new

if [ "$create_new" == "y" ] || [ "$create_new" == "Y" ]; then
    echo "请输入文章标题："
    read title

    if [ -z "$title" ]; then
        echo "❌ 标题不能为空"
        exit 1
    fi

    npx hexo new "$title"
    echo ""
    echo "✅ 文章已创建！请去 source/_posts/ 编辑文章"
else
    echo "⚠️ 跳过创建文章，直接编辑已有文章"
fi

echo "📌 编辑完成后，按回车键继续发布..."
read

echo "🚀 正在发布..."
git add .

echo "📝 请输入提交信息（直接回车则使用默认）："
read msg
if [ -z "$msg" ]; then
    if [ "$create_new" == "y" ] || [ "$create_new" == "Y" ]; then
        msg="新文章: $title $(date '+%Y-%m-%d %H:%M')"
    else
        msg="更新文章 $(date '+%Y-%m-%d %H:%M')"
    fi
fi

git commit -m "$msg"
git push origin main

echo "✅ 发布成功！稍等片刻即可在博客上看到更新。"