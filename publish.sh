#!/bin/bash
echo "📝 请输入文章标题："
read title

if [ -z "$title" ]; then
  echo "❌ 标题不能为空"
  exit 1
fi

npx hexo new "$title"

echo ""
echo "✅ 文章已创建！请去 source/_posts/ 编辑文章"
echo "📌 编辑完成后，按回车键发布..."
read

echo "🚀 正在发布..."
git add .

echo "📝 请输入提交信息（直接回车则使用默认）："
read msg
if [ -z "$msg" ]; then
  msg="新文章: $title $(date '+%Y-%m-%d %H:%M')"
fi

git commit -m "$msg"
git push origin main

echo "✅ 发布成功！稍等片刻即可在博客上看到更新。"