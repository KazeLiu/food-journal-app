# 分享对话界面代码节选

来源：[用户提供的分享对话](https://chatgpt.com/share/6ad62c74-a444-83ea-9f21-6a84cade9c97)。以下为已读取的公开可见 DIL / GenUI 组件原文节选，只作 Flutter 实现参考，不是应用源码，不执行或引入此运行时。固定食物、数值、年份均为原型演示，不能用于真实记录。

选取的组件均使用本地演示状态，没有继续原对话的 `GenUI.issueNewTurn` 按钮。正式 APP 的事实、保存、撤销和授权以 docs 中的契约为准。

## S54 · 四模型设置

```mdx
{@body const models=[{label:"文字主模型",desc:"日常聊天、饮食记录、热量估算",icon:"message-circle",key:"textMain"},{label:"文字兜底模型",desc:"文字主模型请求失败时自动尝试",icon:"shield-check",key:"textBackup"},{label:"图片主模型",desc:"识别食物照片及附带的文字",icon:"image",key:"imageMain"},{label:"图片兜底模型",desc:"图片主模型请求失败时自动尝试",icon:"shield-check",key:"imageBackup"}]}
{@body const [selection,setSelection]=DIL.useState({textMain:"model-text-a",textBackup:"model-text-b",imageMain:"model-vision-a",imageBackup:"model-vision-b"})}
<box border radius="2xl" padding={3} gap={3}>
  <row align="center" justify="between">
    <title size="lg">AI 服务设置</title>
    <badge color="secondary">界面示意</badge>
  </row>
  <box background="surface-secondary" radius="lg" padding={3} gap={1}>
    <row align="center" gap={2}>
      <icon name="key-round" color="secondary"/>
      **统一 API 配置**
    </row>
    <text size="sm" color="secondary">Base URL：api.example.com/v1</text>
    <text size="sm" color="secondary">API Key：••••••••••••</text>
  </box>
  {#each models as model}
    <box gap={2} key={model.key}>
      <row align="center" gap={2}>
        <icon name={model.icon} color="secondary"/>
        <text weight="medium">{model.label}</text>
      </row>
      <select block value={selection[model.key]} onChange={v=>setSelection(p=>({...p,[model.key]:v}))} options={[{label:"model-text-a",value:"model-text-a"},{label:"model-text-b",value:"model-text-b"},{label:"model-vision-a",value:"model-vision-a"},{label:"model-vision-b",value:"model-vision-b"}]}/>
      <text size="xs" color="secondary">{model.desc}</text>
    </box>
  {/each}
  <caption>模型名称为示例，实际可从 API 获取列表或手动输入。</caption>
</box>
```

## S76 · 精简卡片与食物展开

```mdx
{@body const [expanded,setExpanded]=DIL.useState(false)}
<box background="#FFF8F2" theme="light" border radius="2xl" padding={3} gap={3}>
  <row align="center" justify="between">
    <text color="#35313D" weight="medium">聊天中的精简记录卡片</text>
    <text color="#8B7E87" size="xs">交互示例</text>
  </row>
  <box background="#FFFFFF" radius="xl" padding={3} gap={3}>
    <row align="center" justify="between">
      <row align="center" gap={2}>
        <icon name="utensils" color="#C87861"/>
        <text color="#35313D" weight="medium">午餐 · 4 种食物</text>
      </row>
      <icon name="check-circle-2" color="#4F9874"/>
    </row>
    <row align="center" justify="between">
      <title color="#35313D" size="xl">约 850 kcal</title>
      <text color="#8B7E87" size="xs">今天 12:30</text>
    </row>
    <text color="#8B7E87" size="sm">米饭、鸡翅、青菜、可乐</text>
    <button block size="sm" variant="outline" color="secondary" onClick={()=>setExpanded(v=>!v)}>
      {expanded?"收起食物明细":"展开食物明细"} <icon name={expanded?"chevron-up":"chevron-down"} inline/>
    </button>
    {#if expanded}
      <box background="#FFF8F2" radius="lg" padding={3} gap={2}>
        {#each [{name:"一碗米饭",cal:230},{name:"两个鸡翅",cal:300},{name:"一份青菜",cal:120},{name:"一杯可乐",cal:200}] as item}
          <row align="center" justify="between">
            <text color="#514650" size="sm">{item.name}</text>
            <text color="#B36C57" size="sm">约 {item.cal} kcal</text>
          </row>
        {/each}
      </box>
    {/if}
  </box>
  <caption color="#8B7E87">以上热量仅用于演示，实际估算依赖食物和份量。</caption>
</box>
```

## S78 · 逐食物营养

```mdx
{@body const [expanded,setExpanded]=DIL.useState(false)}
{@body const foods=[{name:"米饭",portion:"约 150g",cal:174,p:3.9,f:0.5,c:38.4},{name:"鸡翅",portion:"2 个",cal:260,p:20,f:19,c:2},{name:"清炒青菜",portion:"1 份",cal:110,p:3,f:8,c:7},{name:"可乐",portion:"约 330ml",cal:139,p:0,f:0,c:35}]}
{@body const totals=foods.reduce((a,f)=>({cal:a.cal+f.cal,p:a.p+f.p,f:a.f+f.f,c:a.c+f.c}),{cal:0,p:0,f:0,c:0})}
<box background="#FFF8F2" theme="light" border radius="2xl" padding={3} gap={3}>
  <row align="center" justify="between">
    <text color="#35313D" weight="medium">午餐记录</text>
    <text color="#9A8D97" size="xs">示例数据</text>
  </row>
  <box background="#FFFFFF" radius="xl" padding={3} gap={3}>
    <row align="center" justify="between">
      <row align="center" gap={2}>
        <icon name="utensils" color="#C87861"/>
        <text color="#35313D" weight="medium">午餐 · 4 种食物</text>
      </row>
      <icon name="check-circle-2" color="#4F9874"/>
    </row>
    <row align="end" gap={2}>
      <title color="#35313D" size="2xl">{totals.cal}</title>
      <text color="#8B7E87" size="sm">kcal · 估算</text>
    </row>
    <grid columns={3} gap={2}>
      {#each [{name:"蛋白质",val:totals.p.toFixed(1),unit:"g",bg:"#FCEBE3"},{name:"脂肪",val:totals.f.toFixed(1),unit:"g",bg:"#F0EAFB"},{name:"碳水",val:totals.c.toFixed(1),unit:"g",bg:"#E8F4EA"}] as m}
        <grid-item>
          <box background={m.bg} radius="lg" padding={2} gap={1} align="center">
            <text color="#746774" size="xs">{m.name}</text>
            <text color="#35313D" weight="semibold">{m.val} {m.unit}</text>
          </box>
        </grid-item>
      {/each}
    </grid>
    <text color="#8B7E87" size="sm">米饭、鸡翅、清炒青菜、可乐</text>
    <button block size="sm" color="secondary" variant="outline" onClick={()=>setExpanded(v=>!v)}>
      {expanded?"收起各食物营养":"查看各食物营养"} <icon name={expanded?"chevron-up":"chevron-down"} inline/>
    </button>
    {#if expanded}
      <box gap={2}>
        {#each foods as food}
          <box background="#FFF8F2" radius="lg" padding={3} gap={2}>
            <row justify="between" align="center">
              <box gap={1}>
                <text color="#35313D" size="sm" weight="medium">{food.name}</text>
                <text color="#8B7E87" size="xs">{food.portion}</text>
              </box>
              <text color="#B36C57" weight="medium" size="sm">约 {food.cal} kcal</text>
            </row>
            <row gap={3} wrap="wrap">
              <text color="#8B7E87" size="xs">蛋白质 {food.p}g</text>
              <text color="#8B7E87" size="xs">脂肪 {food.f}g</text>
              <text color="#8B7E87" size="xs">碳水 {food.c}g</text>
            </row>
          </box>
        {/each}
      </box>
    {/if}
  </box>
  <caption color="#9A8D97">营养数值仅为演示估算，实际结果会受食材、烹饪方式和份量影响。</caption>
</box>
```

## S90 · 双点月历

```mdx
{@body const [selectedDay,setSelectedDay]=DIL.useState(19)}
{@body const foodDays=[3,5,8,12,15,17,18,19,22,25]}
{@body const weightDays=[5,15,19]}
<box background="#FFF8F2" theme="light" radius="2xl" padding={3} gap={3}>
  <row justify="between" align="center">
    <title color="#35313D" size="lg">2026 年 10 月</title>
    <row align="center" gap={3}>
      <icon name="chevron-left" color="#8B7E87"/>
      <icon name="chevron-right" color="#8B7E87"/>
    </row>
  </row>
  <grid columns={7} gap={1}>
    {#each ["一","二","三","四","五","六","日"] as weekday}
      <grid-item>
        <box align="center" padding={1}>
          <text color="#8B7E87" size="xs">{weekday}</text>
        </box>
      </grid-item>
    {/each}
    {#each Array.from({length:3},(_,i)=>i) as blank}
      <grid-item><box height="40px"/></grid-item>
    {/each}
    {#each Array.from({length:31},(_,i)=>i+1) as day}
      <grid-item>
        <pressable onClick={()=>setSelectedDay(day)} background={selectedDay===day?"#F9E0D6":"#FFFFFF"} radius="lg" padding={1} align="center" gap={1} minHeight="40px">
          <text color={selectedDay===day?"#A95642":"#514650"} size="sm" weight={selectedDay===day?"semibold":"normal"}>{day}</text>
          <row gap="3px" justify="center" minHeight="5px">
            {#if foodDays.includes(day)}
              <box background="#D78D72" radius="full" size="5px"/>
            {/if}
            {#if weightDays.includes(day)}
              <box background="#9A85C4" radius="full" size="5px"/>
            {/if}
          </row>
        </pressable>
      </grid-item>
    {/each}
  </grid>
  <row gap={3} justify="center">
    <row align="center" gap={1}>
      <box background="#D78D72" radius="full" size="7px"/>
      <text color="#8B7E87" size="xs">饮食记录</text>
    </row>
    <row align="center" gap={1}>
      <box background="#9A85C4" radius="full" size="7px"/>
      <text color="#8B7E87" size="xs">体重记录</text>
    </row>
  </row>
  <box background="#FFFFFF" radius="xl" padding={3} gap={2}>
    <text color="#35313D" weight="medium">10 月 {selectedDay} 日</text>
    {#if foodDays.includes(selectedDay)}
      <row align="center" gap={2}>
        <icon name="utensils" color="#D78D72"/>
        <text color="#514650" size="sm">有饮食记录 · 点击查看食物和营养</text>
      </row>
    {/if}
    {#if weightDays.includes(selectedDay)}
      <row align="center" gap={2}>
        <icon name="scale" color="#9A85C4"/>
        <text color="#514650" size="sm">有体重记录</text>
      </row>
    {/if}
    {#if !foodDays.includes(selectedDay)&&!weightDays.includes(selectedDay)}
      <text color="#8B7E87" size="sm">这一天没有记录，没关系。</text>
    {/if}
  </box>
  <caption color="#8B7E87">点击日期可切换示例内容，记录日期均为演示。</caption>
</box>
```

## S100 · 折叠估算依据

```mdx
{@body const [showBasis,setShowBasis]=DIL.useState(false)}
<box background="#FFF8F2" theme="light" radius="2xl" padding={3} gap={3}>
  <row justify="between" align="center">
    <text color="#35313D" weight="medium">午餐 · 牛肉面</text>
    <text color="#8B7E87" size="xs">示例数据</text>
  </row>
  <box background="#FFFFFF" radius="xl" padding={3} gap={3}>
    <row justify="between" align="end">
      <box gap={1}>
        <text color="#8B7E87" size="xs">估算热量</text>
        <title color="#35313D" size="2xl">约 650 kcal</title>
      </box>
      <icon name="utensils" color="#C87861" size="lg"/>
    </row>
    <grid columns={3} gap={2}>
      {#each [{label:"蛋白质",value:"约 30g",bg:"#FCEBE3"},{label:"脂肪",value:"约 20g",bg:"#F0EAFB"},{label:"碳水",value:"约 88g",bg:"#E8F4EA"}] as item}
        <grid-item>
          <box background={item.bg} radius="lg" padding={2} gap={1} align="center">
            <text color="#746774" size="xs">{item.label}</text>
            <text color="#35313D" size="sm" weight="medium">{item.value}</text>
          </box>
        </grid-item>
      {/each}
    </grid>
    <button block size="sm" variant="outline" color="secondary" onClick={()=>setShowBasis(v=>!v)}>
      {showBasis?"收起估算依据":"查看估算依据"} <icon name={showBasis?"chevron-up":"chevron-down"} inline/>
    </button>
    {#if showBasis}
      <box background="#FFF8F2" radius="lg" padding={3} gap={2}>
        <text color="#514650" weight="medium" size="sm">本次估算假设</text>
        <text color="#786C79" size="sm">· 面条：按普通一碗的份量估算</text>
        <text color="#786C79" size="sm">· 牛肉：按常见牛肉面配料量估算</text>
        <text color="#786C79" size="sm">· 汤和油脂：按一般做法粗略考虑</text>
        <text color="#8B7E87" size="xs">这些是估算时采用的假设，不代表实际测量结果。</text>
      </box>
    {/if}
  </box>
</box>
```

## S114 · 拍照与相册

```mdx
<box background="#FFF8F2" theme="light" radius="2xl" padding={3} gap={3}>
  <row justify="between" align="center">
    <text color="#35313D" weight="medium">AI 教练</text>
    <icon name="ellipsis" color="#8B7E87"/>
  </row>
  <box background="#FFFFFF" radius="xl" padding={3}>
    <row align="center" gap={2}>
      <icon name="plus" color="#9172B8"/>
      <text color="#9A8D97" size="sm">说说你刚刚吃了什么…</text>
      <spacer/>
      <icon name="send" color="#C87861"/>
    </row>
  </box>
  <box background="#FFFFFF" radius="xl" padding={3} gap={3}>
    <text color="#35313D" weight="medium" size="sm">添加图片</text>
    <row gap={3}>
      <box flex="1" background="#FFF8F2" radius="lg" padding={3} align="center" gap={2}>
        <icon name="camera" color="#C87861" size="lg"/>
        <text color="#514650" size="sm">拍照</text>
      </box>
      <box flex="1" background="#F0EAFB" radius="lg" padding={3} align="center" gap={2}>
        <icon name="images" color="#9172B8" size="lg"/>
        <text color="#514650" size="sm">相册</text>
      </box>
    </row>
    <text color="#8B7E87" size="xs">无需选择照片类型，AI 自动判断内容。</text>
  </box>
</box>
```
