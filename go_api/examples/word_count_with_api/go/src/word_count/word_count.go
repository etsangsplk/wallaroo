package main

import (
	"bytes"
	"C"
	"encoding/binary"
	"encoding/gob"
	"fmt"
	"reflect"
	"strings"
	wa "wallarooapi"
	app "wallarooapi/application"
)

//export ApplicationSetup
func ApplicationSetup() *C.char {
	fmt.Println("wallarooapi.Args=", wa.Args)

	wa.Serialize = Serialize
	wa.Deserialize = Deserialize

	application := app.MakeApplication("Word Count Application")
	application.NewPipeline("Split and Count", app.MakeTCPSourceConfig("127.0.0.1", "7010", &Decoder{})).
		ToMulti(&SplitBuilder{}).
		ToStatePartition(&CountWord{}, &WordTotalsBuilder{}, "word totals", &WordPartitionFunction{}, LetterPartition(), true).
		ToSink(app.MakeTCPSinkConfig("127.0.0.1", "7002", &Encoder{}))

	json := application.ToJson()
	fmt.Println(json)

	return C.CString(json)
}

func LetterPartition() []uint64 {
	letterPartition := make([]uint64, 27)

	for i := 0; i < 26; i++ {
		letterPartition[i] = uint64(i + 'a')
	}

	letterPartition[26] = '!'

	return letterPartition
}

type WordPartitionFunction struct {}

func (wpf *WordPartitionFunction) Partition (data interface{}) uint64 {
	word := data.(*string)
	firstLetter := (*word)[0]
	if (firstLetter >= 'a') && (firstLetter <= 'z') {
		return uint64(firstLetter)
	}
	return uint64('!')
}

type Decoder struct {}

func (decoder *Decoder) HeaderLength() uint64 {
	return 4
}

func (decoder *Decoder) PayloadLength(b []byte) uint64 {
	return uint64(binary.BigEndian.Uint32(b[0:4]))
}

func (decoder *Decoder) Decode(b []byte) interface{} {
	return string(b[:])
}

type Split struct {}

func (s *Split) Name() string {
	return "split"
}

func (s *Split) Compute(data interface{}) []interface{} {
	punctuation := " !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
	lines := data.(string)

	words := make([]interface{}, 0)

	for _, line := range strings.Split(lines, "\n") {
		clean_line := strings.Trim(strings.ToLower(line), punctuation)
		for _, word := range strings.Split(clean_line, " ") {
			clean_word := strings.Trim(word, punctuation)
			words = append(words, &clean_word)
		}
	}

	return words
}

type SplitBuilder struct {}

func (sb *SplitBuilder) Build() interface{} {
	return &Split{}
}

type CountWord struct {}

func (cw *CountWord) Name() string {
	return "count word"
}

func (cw *CountWord) Compute(data interface{}, state interface{}) (interface{}, bool) {
	word := data.(*string)
	wordTotals := state.(*WordTotals)
	wordTotals.Update(*word)
	return wordTotals.GetCount(*word), true
}

type WordCount struct {
	Word string
	Count uint64
}

func MakeWordTotals() *WordTotals {
	return &WordTotals{ make(map[string]uint64) }
}

type WordTotals struct {
	WordTotals map[string]uint64
}

func (wordTotals *WordTotals) Update(word string) {
	total, found := wordTotals.WordTotals[word]
	if !found {
		total = 0
	}
	wordTotals.WordTotals[word] = total + 1
}

func (wordTotals *WordTotals) GetCount(word string) *WordCount {
	return &WordCount{word, wordTotals.WordTotals[word]}
}

type WordTotalsBuilder struct {}

func (wtb *WordTotalsBuilder) Name() string {
	return "word totals builder"
}

func (wtb *WordTotalsBuilder) Build() interface{} {
	return MakeWordTotals()
}

type Encoder struct {}

func (encoder *Encoder) Encode(data interface{}) []byte {
	word_count := data.(*WordCount)
	msg := fmt.Sprintf("%s => %d\n", word_count.Word, word_count.Count)
	fmt.Println(msg)
	return []byte(msg)
}

func main() {
}

func Serialize(c interface{}) []byte {
	switch t := c.(type) {
	case *WordPartitionFunction:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 1)
		return buff
	case *Decoder:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 2)
		return buff
	case *Split:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 3)
		return buff
	case *SplitBuilder:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 4)
		return buff
	case *CountWord:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 5)
		return buff
	case *WordCount:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 6)
		var b bytes.Buffer
		enc := gob.NewEncoder(&b)
		enc.Encode(6)
		enc.Encode(c)
		return append(buff, b.Bytes()...)
	case *WordTotals:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 7)
		var b bytes.Buffer
		enc := gob.NewEncoder(&b)
		enc.Encode(c)
		return append(buff, b.Bytes()...)
	case *WordTotalsBuilder:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 8)
		return buff
	case *Encoder:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 9)
		return buff
	case *string:
		buff := make([]byte, 4)
		binary.BigEndian.PutUint32(buff, 10)
		var b bytes.Buffer
		enc := gob.NewEncoder(&b)
		enc.Encode(c)
		return append(buff, b.Bytes()...)
	default:
		fmt.Println("SERIALIZE MISSED A CASE")
		fmt.Println(reflect.TypeOf(t))
	}
	return nil
}

func Deserialize(buff []byte) interface{} {
	componentType := binary.BigEndian.Uint32(buff[:4])
	payload := buff[4:]

	switch componentType {
	case 1:
		return &WordPartitionFunction{}
	case 2:
		return &Decoder{}
	case 3:
		return &Split{}
	case 4:
		return &SplitBuilder{}
	case 5:
		return &CountWord{}
	case 6:
		b := bytes.NewBuffer(payload)
		dec := gob.NewDecoder(b)
		var wc WordCount
		dec.Decode(&wc)
		return &wc
	case 7:
		b := bytes.NewBuffer(payload)
		dec := gob.NewDecoder(b)
		var wt WordTotals
		dec.Decode(&wt)
		return &wt
	case 8:
		return &WordTotalsBuilder{}
	case 9:
		return &Encoder{}
	case 10:
		b := bytes.NewBuffer(payload)
		dec := gob.NewDecoder(b)
		var s string
		dec.Decode(&s)
		return &s
	default:
		fmt.Println("DESERIALIZE MISSED A CASE")
	}
	return nil
}
