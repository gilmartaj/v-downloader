module main

import io
import net.http
import net.http.mime
import net.ssl
import net.urllib
import os
import rand
import sync
import time

const megabyte = 1048576

const tempo_espera = 1

const user_agent = 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/113.0'

const nova_linha = u8(10)

const retorno_de_carro = u8(13)

const esc = u8(27).ascii_str()

[heap]
struct Dados {
	tamanho_total u64
mut:
	total_baixado u64
	arquivo       shared os.File
	info          shared os.File = unsafe { nil }
	mutex         &sync.Mutex    = unsafe { nil }
}

[heap]
struct Baixador {
	link   string
	inicio u64
	fim    u64
	// nome_arquivo string
	numero u8
mut:
	baixado u64
	dados   &Dados       = unsafe { nil }
	conexao &ssl.SSLConn = unsafe { nil }
}

fn host_porta_caminho(link string) (string, int, string) {
	url := urllib.parse(link) or { panic('Erro ao ler link') }
	caminho := '/${url.escaped_path().trim_left('/')}' +
		if url.query().len > 0 { '?${url.query().encode()}' } else { '' }
	porta := if url.port().int() == 0 {
		if url.scheme == 'http' {
			80
		} else if url.scheme == 'https' {
			443
		} else {
			panic('Porta desconhecida')
		}
	} else {
		url.port().int()
	}
	return url.hostname(), porta, caminho
}

fn ler_cabecalhos(mut ssl_conn ssl.SSLConn) ![]u8 {
	mut br := io.new_buffered_reader(reader: ssl_conn, cap: 1)
	mut buf := []u8{len: 1, cap: 1}
	mut cabecalhos := []u8{}

	mut cont := 0
	mut ant := false

	for {
		k := br.read(mut buf)!
		if k == 0 {
			break
		}
		cabecalhos << buf[0]
		print(buf[0].ascii_str())
		if buf[0] == nova_linha && ant {
			cont++
		}
		if buf[0] == retorno_de_carro {
			ant = true
		} else {
			ant = false
		}
		if buf[0] != retorno_de_carro && buf[0] != nova_linha {
			cont = 0
		}
		if cont == 2 {
			break
		}
	}
	return cabecalhos
}

fn criar_conexao_ssl(link string, inicio u64, fim u64) !&ssl.SSLConn {
	mut conexao := ssl.new_ssl_conn() or { panic('Erro ao abrir conexão') }
	host, porta, caminho := host_porta_caminho(link)

	conexao.dial(host, porta)!
	conexao.write_string('GET ${caminho} HTTP/1.1\r\nHost: ${host}\nUser-Agent: ${user_agent}')!
	if fim > 0 {
		conexao.write_string('\nRange: bytes=${inicio}-${fim}')!
	}
	conexao.write_string('\nConnection: close\r\n\r\n')!

	return conexao
}

fn Baixador.new(mut dados Dados, link string, inicio u64, fim u64, baixado u64, numero u8) &Baixador {
	mut conexao := criar_conexao_ssl(link, inicio + baixado, fim) or { panic('erro ssl') }
	ler_cabecalhos(mut conexao) or { panic('algum erro') }
	return &Baixador{
		dados: dados
		link: link
		inicio: inicio
		fim: fim
		conexao: conexao
		baixado: baixado
		numero: numero
	}
}

fn (mut baixador Baixador) baixar() {
	buffer := [megabyte]u8{}
	for baixador.inicio + baixador.baixado < baixador.fim {
		bytes_lidos := baixador.conexao.socket_read_into_ptr(&buffer[0], megabyte) or {
			println('Erro ao baixar')
			return
		}
		lock baixador.dados.arquivo {
			unsafe { baixador.dados.arquivo.write_ptr_at(&buffer[0], bytes_lidos, baixador.inicio +
				baixador.baixado) }
			baixador.dados.arquivo.flush()
		}
		baixador.baixado += u64(bytes_lidos)
		// println(baixador.inicio + baixador.baixado)
		baixador.dados.total_baixado += u64(bytes_lidos)
		lock baixador.dados.info {
			unsafe { baixador.dados.info.write_ptr_at(&baixador.baixado, 8, baixador.numero * 8) }
		}
		// println('${u8(27).ascii_str()}[4A\r${u8(27).ascii_str()}[0J${baixador.dados.total_baixado} Bytes = ${baixador.dados.total_baixado/u64(megabyte)} MB')
		println('${esc}[4A\r${esc}[0J')
		println('\n Tamanho total: ${baixador.dados.tamanho_total} bytes = ${baixador.dados.tamanho_total / megabyte} MB')
		println('\n Baixado: ${baixador.dados.total_baixado} bytes = ${baixador.dados.total_baixado / megabyte} MB')
		time.sleep(tempo_espera)
	}
	if baixador.baixado > baixador.fim - baixador.inicio {
		dif := baixador.baixado - (baixador.fim - baixador.inicio)
		baixador.baixado -= dif
		lock baixador.dados.info {
			baixador.dados.total_baixado -= dif
			unsafe { baixador.dados.info.write_ptr_at(&baixador.baixado, 8, baixador.numero * 8) }
		}
	}
}

fn Baixador.criar_da_conexao(mut dados Dados, conexao &ssl.SSLConn, inicio u64, fim u64, baixado u64, numero u8) &Baixador {
	return &Baixador{
		dados: dados
		conexao: unsafe { conexao }
		inicio: inicio
		fim: fim
		baixado: baixado
		numero: numero
	}
}

fn (mut b Baixador) teste() {
	println('aaa')
}

fn montar_nome(content string) !string {
	inicio := content.index('filename="')! + 10
	fim := content.index_after('"', inicio)
	return urllib.path_unescape(content[inicio..fim])!
}

fn abrir_arquivo(caminho string, tamanho u64) !os.File {
	if !os.exists(caminho) {
		mut arquivo := os.create(caminho)!
		arquivo.close()
		if tamanho != 0 {
			os.truncate(caminho, tamanho)!
			// v := 0
			// arquivo.write_ptr_at(&v, 1, tamanho-1)
		}
	} else {
		if tamanho != 0 && os.file_size(caminho) != tamanho {
			panic('O tamanho do arquivo é diferente.')
		}
	}
	return os.open_file(caminho, 'r+')!
}

fn main() {
	mut contador_tempo := time.new_stopwatch()
	contador_tempo.start()

	qtd_threads := (os.args[2] or { '1' }).parse_uint(10, 8) or {
		panic('Quantidade de threads inválida.')
	}

	link := os.args[1].str()
	mut conexao := criar_conexao_ssl(link, 0, 0) or { panic('Erro ao criar conexão') }
	bytes_cabecalhos := ler_cabecalhos(mut conexao) or { panic('') }
	linhas := bytes_cabecalhos.bytestr().split_any('\r\n').filter(it != '')
	println(linhas[0])
	if linhas[0].split(' ').filter(it != '')[1] != '200' {
		return
	}
	mut cabecalhos := map[string]string{}
	for linha in linhas[1..] {
		posicao_separador := linha.index(':') or { -1 }
		if posicao_separador > 0 {
			chave := linha[..posicao_separador].trim_space().to_lower()
			valor := linha[posicao_separador + 1..].trim_space()
			cabecalhos[chave] = valor
		}
	}
	tamanho_arquivo := cabecalhos['content-length'].parse_uint(10, 64) or { u64(0) }
	println(cabecalhos['content-length'])
	nome_arquivo := (os.args[3] or {
		montar_nome(cabecalhos['content-disposition']) or {
			mut nome := rand.uuid_v4()
			extensao := mime.get_default_ext(cabecalhos['content-type'])
			if extensao != '' {
				nome += '.${extensao}'
			}
			nome
		}
	}).str()
	println(nome_arquivo)

	shared arquivo := abrir_arquivo(nome_arquivo, tamanho_arquivo) or {
		panic('Erro ao criar arquivo')
	}
	defer {
		lock arquivo {
			arquivo.close()
		}
	}
	nome_arquivo_info := nome_arquivo + '.downloadinfo'
	shared info := abrir_arquivo(nome_arquivo_info, qtd_threads * 8) or {
		panic('Erro ao criar arquivo')
	}
	defer {
		lock info {
			if info.is_opened {
				info.close()
			}
		}
	}

	mut threads := []thread{}
	mut baixadores := []Baixador{}

	// defer{
	conexao.shutdown() or {}
	//}

	mut dados := &Dados{
		arquivo: arquivo
		total_baixado: 0
		info: info
		tamanho_total: tamanho_arquivo
	}
	lock info {
		baixado_thread := info.read_raw_at[u64](0) or { u64(0) }
		if baixado_thread < tamanho_arquivo / qtd_threads {
			baixadores << Baixador.new(mut dados, link, 0, tamanho_arquivo / qtd_threads,
				baixado_thread, u8(0))
		}
	}
	lock info {
		if tamanho_arquivo != 0 {
			for i := u64(1); i < qtd_threads; i++ {
				baixado_thread := info.read_raw_at[u64](i * 8) or { u64(0) }
				if baixado_thread < (tamanho_arquivo * (i + 1) / qtd_threads - 1) - (tamanho_arquivo * i / qtd_threads) {
					baixadores << Baixador.new(mut dados, link, tamanho_arquivo * i / qtd_threads,
						tamanho_arquivo * (i + 1) / qtd_threads, baixado_thread, u8(i))
				}
			}
		} else {
			println('Tamanho do arquivo não informado...')
		}

		for i in 0 .. qtd_threads {
			dados.total_baixado += info.read_raw_at[u64](i * 8) or { u64(0) }
		}
	}

	if qtd_threads != 1 {
		for mut baixador in baixadores {
			threads << spawn baixador.baixar()
		}

		threads.wait()
	} else {
		baixadores[0].baixar()
		println('Baixando com 1 thread\n\n\n')
	}

	/*
	t1 := spawn baixador.baixar()

    mut baixador2 := Baixador.new(mut dados, link, tamanho_arquivo/3, tamanho_arquivo/3*2, u8(1))

    t2 := spawn baixador2.baixar()

    mut baixador3 := Baixador.new(mut dados, link, tamanho_arquivo/3*2, tamanho_arquivo, u8(2))

    t3 := spawn baixador3.baixar()

    t1.wait()
    t2.wait()
    t3.wait()*/
	lock info {
		info.close()
	}
	if dados.total_baixado == tamanho_arquivo {
		os.rm(nome_arquivo_info) or { println('Erro ao remover arquivo .downloadinfo') }
	}

	// rlock dados.total_baixado{
	println(dados.total_baixado)
	println(tamanho_arquivo)
	//}
	// println(baixador.baixado + baixador2.baixado + baixador3.baixado)

	println('Tempo total: ${contador_tempo.elapsed()}')

	for mut baixador in baixadores {
		// println(baixador)
		baixador.conexao.shutdown() or {}
	}

	// println(cabecalhos.bytestr())

	// mut b := Baixador.new(unsafe{nil},'https://www.google.com/hhh/kkk?j=u7u',0,0)
	// println(b.caminho)
	// t := spawn b.teste()
	// t.wait()
}
