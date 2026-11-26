#!/usr/bin/env node
// patch-yaml.mjs — аккуратно правит машинный слой dsh ($DSH_HOME/cordis.patch.yml).
//
// В этом файле у пользователя живут и MCP-серверы, и другие плагины, причём
// несколько `- insert:` подряд перекрывают друг друга. Поэтому установщик
// не дописывает второй блок, а добавляет запись в конец уже существующего.
//
// Команды:
//   node scripts/patch-yaml.mjs add    <file> <id> <name>   — вставить запись
//   node scripts/patch-yaml.mjs remove <file> <id>          — убрать запись
//   node scripts/patch-yaml.mjs has    <file> <id>          — код 0, если запись есть

import fs from "node:fs";

const [, , command, file, ...rest] = process.argv;

if (!command || !file) usage();
if (command === "has" || command === "remove") {
  if (!rest[0]) usage();
} else if (command === "add") {
  if (!rest[0] || !rest[1]) usage();
} else {
  usage();
}

function usage() {
  console.error("usage:");
  console.error("  patch-yaml.mjs add    <file> <id> <name>");
  console.error("  patch-yaml.mjs remove <file> <id>");
  console.error("  patch-yaml.mjs has    <file> <id>");
  process.exit(2);
}

const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function readLines(target) {
  if (!fs.existsSync(target)) return null;
  const text = fs.readFileSync(target, "utf8");
  return { raw: text, lines: text.split("\n") };
}

function findEntry(lines, id) {
  const pattern = new RegExp(`^\\s*-\\s*id:\\s*${escapeRegExp(id)}\\s*$`);
  return lines.findIndex((line) => pattern.test(line));
}

function indentOf(line) {
  return line.match(/^\s*/)[0].length;
}

// Конец блока: первая строка, которая уже не принадлежит `- insert:`
function blockEnd(lines, start) {
  let end = start + 1;
  while (end < lines.length) {
    const line = lines[end];
    if (line.trim() === "") { end += 1; continue; }
    if (!/^\s/.test(line)) break;
    end += 1;
  }
  while (end > start + 1 && lines[end - 1].trim() === "") end -= 1;
  return end;
}

function entryLines(id, name, indent) {
  const pad = " ".repeat(indent);
  return [`${pad}- id: ${id}`, `${pad}  name: ${name}`];
}

function commandHas() {
  const data = readLines(file);
  if (!data) process.exit(1);
  process.exit(findEntry(data.lines, rest[0]) >= 0 ? 0 : 1);
}

function commandAdd() {
  const id = rest[0];
  const name = rest[1];
  const data = readLines(file);
  if (data && findEntry(data.lines, id) >= 0) {
    console.log("already present");
    return;
  }

  const header = [
    "# Машинный слой dsh: применяется после слоя профиля и до --patch приложения.",
    "# Профиль приложение пересоздаёт, а этот файл — нет.",
  ];

  if (!data || data.raw.trim() === "" || data.raw.trim() === "[]") {
    const block = [...header, "- insert:", ...entryLines(id, name, 4)];
    fs.writeFileSync(file, block.join("\n") + "\n", "utf8");
    console.log("created");
    return;
  }

  const lines = data.lines;
  const insertAt = lines.findIndex((line) => /^- insert:\s*$/.test(line));

  if (insertAt < 0) {
    if (lines[lines.length - 1] !== "") lines.push("");
    lines.push("- insert:", ...entryLines(id, name, 4));
    fs.writeFileSync(file, lines.join("\n"), "utf8");
    console.log("appended");
    return;
  }

  const end = blockEnd(lines, insertAt);
  const indent = (() => {
    for (let i = insertAt + 1; i < end; i += 1) {
      if (/^\s*-\s*id:/.test(lines[i])) return indentOf(lines[i]);
    }
    return 4;
  })();

  const next = [
    ...lines.slice(0, end),
    ...entryLines(id, name, indent),
    ...lines.slice(end),
  ];
  fs.writeFileSync(file, next.join("\n"), "utf8");
  console.log("inserted");
}

function commandRemove() {
  const id = rest[0];
  const data = readLines(file);
  if (!data) {
    console.log("no file");
    return;
  }
  const lines = data.lines;
  const index = findEntry(lines, id);
  if (index < 0) {
    console.log("not found");
    return;
  }

  const indent = indentOf(lines[index]);
  let end = index + 1;
  while (end < lines.length) {
    const line = lines[end];
    if (line.trim() === "") { end += 1; continue; }
    if (indentOf(line) <= indent) break;
    end += 1;
  }
  while (end > index + 1 && lines[end - 1].trim() === "") end -= 1;

  let kept = [...lines.slice(0, index), ...lines.slice(end)];

  // если `- insert:` остался без единой записи — убираем и его
  let changed = true;
  while (changed) {
    changed = false;
    for (let i = 0; i < kept.length; i += 1) {
      if (!/^- insert:\s*$/.test(kept[i])) continue;
      if (blockEnd(kept, i) === i + 1) {
        kept.splice(i, 1);
        changed = true;
        break;
      }
    }
  }

  const hasTopLevelEntry = kept.some((line) => /^- /.test(line));
  const meaningful = kept.filter((line) => line.trim() !== "" && !line.trim().startsWith("#"));

  if (meaningful.length === 0 || !hasTopLevelEntry) {
    const comments = kept.filter((line) => line.trim().startsWith("#"));
    const output = [...comments, ...(comments.length ? [""] : []), "[]", ""];
    fs.writeFileSync(file, output.join("\n"), "utf8");
    console.log("emptied");
    return;
  }

  fs.writeFileSync(file, kept.join("\n"), "utf8");
  console.log("removed");
}

if (command === "has") commandHas();
else if (command === "add") commandAdd();
else commandRemove();
