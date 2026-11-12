// 缺片检测的标准答案：索引里的每部片「我到底有没有」。
// 每一条都是线上会出现的形态：重拍片、同名不同片、繁体文件名、罗马数字、全角、重音、
// 剧集按季分目录、Stream 认错年份的 id、只有中文名 / 只有英文名、一份片的几个拷贝……
// expect：2 = 确定已有（id 相同）  1 = 很可能已有（片名 + 年份对上，库里那份没有可信 id）
//         0 = 没有（该显示为缺片）   null = 信息不够，答案不唯一（不计分）

/* 索引里的片：[id, 中文名, 原名, 年份] */
export const movies = [
  [438631, '沙丘', 'Dune', 2021],
  [841, '沙丘', 'Dune', 1984],
  [496243, '寄生虫', '기생충', 2019],
  [475557, '小丑', 'Joker', 2019],
  [889737, '小丑2：双重妄想', 'Joker: Folie à Deux', 2024],
  [8587, '狮子王', 'The Lion King', 1994],
  [420818, '狮子王', 'The Lion King', 2019],
  [700001, '惊变', 'Fear', 2023],
  [700002, '惊变', 'Fear', 2024],
  [299534, '复仇者联盟4：终局之战', 'Avengers: Endgame', 2019],
  [1367, '洛奇2', 'Rocky II', 1979],
  [194, '天使爱美丽', 'Amélie', 2001],
  [614, '误杀', 'Sheep Without a Shepherd', 2019],
  [9999, '惊魂记', 'Psycho Night', 1985],
  [10775, '无间道', '無間道', 2002],
  [79, '英雄', '英雄', 2002],
  [414906, '新蝙蝠侠', 'The Batman', 2022],
  [693134, '沙丘：第二部', 'Dune: Part Two', 2024],
  [999999, '惊天魔盗团', 'Now You See Me', 2013],
  [155, '蝙蝠侠：黑暗骑士', 'The Dark Knight', 2008],
  [27205, '盗梦空间', 'Inception', 2010],
  [157336, '星际穿越', 'Interstellar', 2014],
  [372058, '你的名字。', '君の名は。', 2016],
  [129, '千与千寻', '千と千尋の神隠し', 2001],
  [546554, '利刃出鞘', 'Knives Out', 2019],
  [661374, '利刃出鞘2', 'Glass Onion: A Knives Out Mystery', 2022],
  [12445, '哈利·波特与死亡圣器(下)', 'Harry Potter and the Deathly Hallows: Part 2', 2011],
  [12444, '哈利·波特与死亡圣器(上)', 'Harry Potter and the Deathly Hallows: Part 1', 2010],
  [550, '搏击俱乐部', 'Fight Club', 1999],
  [680, '低俗小说', 'Pulp Fiction', 1994],
  [37165, '楚门的世界', 'The Truman Show', 1998],
  [301502, '血战钢锯岭', 'Hacksaw Ridge', 2016],
  [800001, '归途', 'Home', 2015],
];
/* 剧集源里的剧：[id, 中文名, 原名, 首播年] */
export const shows = [
  [1399, '权力的游戏', 'Game of Thrones', 2011],
  [42009, '黑镜', 'Black Mirror', 2011],
  [66732, '怪奇物语', 'Stranger Things', 2016],
  [94997, '龙之家族', 'House of the Dragon', 2022],
  [1396, '绝命毒师', 'Breaking Bad', 2008],
  [60059, '风骚律师', 'Better Call Saul', 2015],
  [210000, '三体', '三体', 2023],
  [108545, '三体', '3 Body Problem', 2024],
];

/* 片库总账（Received.json）里的条目 —— Stream 那边给的形状 */
export const items = [
  // ① 认下来的、id 对得上
  { key: 'm1', kind: 'movie', name: 'Dune.2021.2160p.mkv', tmdb: 438631, type: 'movie', title: '沙丘', orig: 'Dune', year: '2021', guessYear: '2021' },
  { key: 'm1b', kind: 'movie', name: 'Dune.2021.1080p.mkv', tmdb: 438631, type: 'movie', title: '沙丘', orig: 'Dune', year: '2021', guessYear: '2021' },
  { key: 'm2', kind: 'movie', name: 'Joker.2019.mkv', tmdb: 475557, type: 'movie', title: '小丑', orig: 'Joker', year: '2019', guessYear: '2019' },
  { key: 'm3', kind: 'movie', name: 'The.Lion.King.2019.mkv', tmdb: 420818, type: 'movie', title: '狮子王', orig: 'The Lion King', year: '2019', guessYear: '2019' },
  { key: 'm4', kind: 'movie', name: 'Fear.2023.mkv', tmdb: 700001, type: 'movie', title: '惊变', orig: 'Fear', year: '2023', guessYear: '2023' },
  { key: 'm5', kind: 'movie', name: 'Inception.2010.mkv', tmdb: 27205, type: 'movie', title: '盗梦空间', orig: 'Inception', year: '2010', guessYear: '2010' },
  { key: 'm5b', kind: 'movie', name: 'Inception.mkv', tmdb: 27205, type: 'movie', title: '盗梦空间', orig: 'Inception', year: '2010' },
  // ② 没认下来（Stream 那边 TMDB 查无 / 还没查）
  { key: 'u1', kind: 'movie', name: '寄生虫.Parasite.2019.mkv', guess: '寄生虫', guessZh: '寄生虫', guessEn: 'Parasite', guessYear: '2019' },
  { key: 'u2', kind: 'movie', name: '復仇者聯盟4：終局之戰.2019.mkv', guess: '復仇者聯盟4：終局之戰', guessZh: '復仇者聯盟4：終局之戰', guessYear: '2019' },
  { key: 'u3', kind: 'movie', name: 'Rocky.2.1979.mkv', guess: 'Rocky 2', guessEn: 'Rocky 2', guessYear: '1979' },
  { key: 'u4', kind: 'movie', name: 'Amelie.2001.mkv', guess: 'Amelie', guessEn: 'Amelie', guessYear: '2001' },
  { key: 'u5', kind: 'movie', name: '无间道.mkv', guess: '无间道', guessZh: '无间道' },
  { key: 'u6', kind: 'movie', name: '英雄.mkv', guess: '英雄', guessZh: '英雄' },
  { key: 'u7', kind: 'movie', name: 'The.Batman.2022.mkv', guess: 'Batman', guessEn: 'Batman', guessYear: '2022' },
  { key: 'u8', kind: 'movie', name: '沙丘2.Dune.Part.2.2024.mkv', guess: '沙丘2', guessZh: '沙丘2', guessEn: 'Dune Part 2', guessYear: '2024' },
  { key: 'u9', kind: 'movie', name: 'Dune.mkv', guess: 'Dune', guessEn: 'Dune' },
  { key: 'u10', kind: 'movie', name: 'ＩＮＴＥＲＳＴＥＬＬＡＲ.2014.mkv', guess: 'ＩＮＴＥＲＳＴＥＬＬＡＲ', guessEn: 'ＩＮＴＥＲＳＴＥＬＬＡＲ', guessYear: '2014' },
  { key: 'u11', kind: 'movie', name: '你的名字.2016.mkv', guess: '你的名字', guessZh: '你的名字', guessYear: '2016' },
  { key: 'u12', kind: 'movie', name: 'Harry.Potter.and.the.Deathly.Hallows.Part.II.2011.mkv', guess: 'Harry Potter and the Deathly Hallows Part II', guessEn: 'Harry Potter and the Deathly Hallows Part II', guessYear: '2011' },
  { key: 'u13', kind: 'movie', name: 'Fight Club (1999).mkv', guess: 'Fight Club', guessEn: 'Fight Club', guessYear: '1998' },
  { key: 'u14', kind: 'movie', name: 'movie.mkv', guess: 'movie', guessEn: 'movie' },
  // 港台译名：中文名对不上，英文名对得上
  { key: 'u15', kind: 'movie', name: '真人Show.The.Truman.Show.1998.mkv', guess: '真人Show', guessZh: '真人Show', guessEn: 'The Truman Show', guessYear: '1998' },
  { key: 'u16', kind: 'movie', name: '鋼鐵英雄.Hacksaw.Ridge.2016.mkv', guess: '鋼鐵英雄', guessZh: '鋼鐵英雄', guessEn: 'Hacksaw Ridge', guessYear: '2016' },
  // 短英文名撞车：同年另一部叫 Home 的片，中文名完全不同
  { key: 'u17', kind: 'movie', name: '疯狂外星人.Home.2015.mkv', guess: '疯狂外星人', guessZh: '疯狂外星人', guessEn: 'Home', guessYear: '2015' },
  // ③ Stream 认错了（id 的年份和文件名的年份差了几十年）：id 不可信，按文件名的片名 + 年份比
  { key: 'w1', kind: 'movie', name: '误杀.2019.1080p.mkv', tmdb: 9999, type: 'movie', title: '惊魂记', orig: 'Psycho Night', year: '1985', guess: '误杀', guessZh: '误杀', guessYear: '2019' },
  // ④ id 和索引的对不上，但片名 + 年份一模一样、索引里也没有库里那个 id：多半是某一边认错了
  { key: 'c1', kind: 'movie', name: 'Now.You.See.Me.2013.mkv', tmdb: 75656, type: 'movie', title: '惊天魔盗团', orig: 'Now You See Me', year: '2013', guessYear: '2013' },
  // ⑤ 剧集：按季分目录，目录年份是这一季的
  { key: 's1', kind: 'series', name: 'Game.of.Thrones.S01', tmdb: 1399, type: 'tv', title: '权力的游戏', orig: 'Game of Thrones', year: '2011', season: 1, episodes: 10 },
  { key: 's2', kind: 'series', name: 'Game.of.Thrones.S08', tmdb: 1399, type: 'tv', title: '权力的游戏', orig: 'Game of Thrones', year: '2011', season: 8, episodes: 6 },
  { key: 's3', kind: 'series', name: '黑镜.第三季.2016', guess: '黑镜', guessZh: '黑镜', guessEn: 'Black Mirror', guessYear: '2016', season: 3, episodes: 6 },
  { key: 's4', kind: 'series', name: '龙之家族.第二季.2024', guess: '龍之家族', guessZh: '龍之家族', guessYear: '2024', season: 2, episodes: 8 },
  { key: 's5', kind: 'series', name: 'Breaking.Bad.S05.2012', guess: 'Breaking Bad', guessEn: 'Breaking Bad', guessYear: '2007', season: 5, episodes: 16 },
  { key: 's6', kind: 'series', name: '三体.2023', guess: '三体', guessZh: '三体', guessYear: '2023', episodes: 30 },
  // ⑥ 类型串台：库里一部「电影」的 TMDB id 恰好等于某部剧的 id —— 两套编号，不能互相认
  { key: 'x1', kind: 'movie', name: 'Some.Movie.2001.mkv', tmdb: 1396, type: 'movie', title: '某电影', orig: 'Some Movie', year: '2001', guessYear: '2001' },
];

export const expectMovie = {
  438631: 2,   // id 相同
  841: null,   // 「Dune.mkv」没年份、同名两部：说不准是哪一部
  496243: 1,   // 寄生虫 2019：没 id，片名 + 年份
  475557: 2,
  889737: 0,   // 小丑2 不是小丑
  8587: 0,     // 狮子王 1994：库里只有 2019 那部
  420818: 2,
  700001: 2,
  700002: 0,   // 惊变 2024：库里那部有 id，是 2023 的另一部，不能按「同名、差一年」顺手藏掉
  299534: 1,   // 繁体文件名
  1367: 1,     // Rocky 2 ↔ Rocky II
  194: 1,      // Amelie ↔ Amélie
  614: 1,      // 误杀 2019：库里那份的 id 是认错的，按文件名对上
  9999: 0,     // 惊魂记 1985：库里那份 id 认错了，其实没有这部
  10775: 1,    // 无间道：没年份，但片名独一无二
  79: null,    // 英雄：两个字、没年份，太常见，说不准
  414906: 1,   // Batman ↔ The Batman 2022
  693134: 1,   // 沙丘2 ↔ 沙丘：第二部、Dune Part 2 ↔ Dune: Part Two
  999999: 1,   // 惊天魔盗团 2013：两边 id 不同，片名年份全同、索引里没有库里那个 id
  155: 0,
  27205: 2,
  157336: 1,   // 全角 ＩＮＴＥＲＳＴＥＬＬＡＲ
  372058: 1,   // 你的名字 ↔ 你的名字。
  129: 0,
  546554: 0,
  661374: 0,
  12445: 1,    // Part II ↔ Part 2
  12444: 0,    // 上集没有
  550: 1,      // Fight Club：文件名年份 1998，差一年
  680: 0,
  37165: 1,    // 港台译名「真人Show」，英文名对上、同年
  301502: 1,   // 港台译名「鋼鐵英雄」，英文名对上、同年
  800001: 0,   // 「Home」2015 撞名：库里那部中文名是「疯狂外星人」，不是这部「归途」
};
export const expectTV = {
  1399: 2,
  42009: 1,    // 黑镜：第三季目录写 2016，首播 2011
  66732: 0,
  94997: 1,    // 龍之家族（繁体）第二季 2024，首播 2022
  1396: null,  // Breaking Bad：目录年份 2007 早于首播一年，差一年认
  60059: 0,
  210000: 1,   // 三体 2023：同名两部，年份对上的那部
  108545: 0,   // 3 Body Problem 2024：库里的是 2023 那部
};
expectTV[1396] = 1;
