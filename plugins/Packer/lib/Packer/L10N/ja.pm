package Packer::L10N::ja;

use strict;
use base 'Packer::L10N::en_us';
use utf8;

use vars qw( %Lexicon );

%Lexicon = (
    '_PLUGIN_DESCRIPTION'   => '記事単位のインポート・エクスポートを提供します。',
    'Export error.'         => 'エクスポート中にエラーが発生しました。',
    'Export [_1]'           => '[_1]のエクスポート',
    'Start the export.'     => 'エクスポートを開始します。',
    'Please do not do during other operations.' => '完了するまで他の操作を行わないで下さい。',
    'Start'                 => '開始',
    "Exporting...([_1]-[_2])" => '[_1]件目から[_2]件目をエクスポート中です...',
    'Export finished. Start download.' => 'エクスポートが完了しました。ダウンロードを開始します。',
    'Manual download here.' => '自動でダウンロードが始まらない場合はこちらからダウンロードして下さい',
    'Import [_1]'           => '[_1]のインポート',
    'Start the import.'     => 'インポートを開始します。',
    'An error in the reading of the ZIP file.' => 'ZIPファイルの展開に失敗しました。ファイルが壊れているか、正しくアップロードされなかった可能性があります。',
    'Export finished.'      => 'インポートを完了しました。',
    'Importing...(The remnant number of [_1])' => 'インポート中 残り[_1]件',
    'entries'               => 'ブログ記事',
    'pages'                 => 'ウェブページ',
    "Unsupported field type '[_1]'([_2]). skipped." => "'[_1]'（[_2]）は未対応のカスタムフィールドタイプです。スキップしました。",
);

1;